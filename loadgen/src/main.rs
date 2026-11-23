//! Lightweight load generator for an OpenAI-compatible streaming endpoint.
//!
//! Holds N concurrent `/v1/chat/completions` streams open over keep-alive HTTP/1.1
//! connections, timestamps every SSE event on arrival, and prints a JSON summary.
//! It does no tokenisation and no per-event JSON parsing, so its CPU cost per token
//! stays well below that of the gateway it is measuring.

use std::io;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const USAGE: &str = "\
loadgen --concurrency N [options]
  --addr HOST:PORT      gateway address                  [127.0.0.1:8000]
  --model NAME          model name sent in the request   [Qwen/Qwen3-0.6B]
  --concurrency N       streams held open
  --duration SECS       total run time                   [30]
  --warmup SECS         leading time excluded from stats [5]
  --ramp SECS           time over which streams start    [2]
  --max-tokens N        mean output length               [1024]
  --spread N            output length is mean +/- spread [300]
  --prompts FILE        one prompt per line              [built-in prompt]
  --seed N              RNG seed for lengths and prompts [1]
  --raw FILE            write per-event CSV: conn,local_port,request,event,t_mono_ns
  --completions FILE    write completed requests as CSV: conn,request,t_mono_ns
  --out FILE            also write the JSON summary here";

struct Config {
    addr: String,
    model: String,
    concurrency: usize,
    duration: f64,
    warmup: f64,
    ramp: f64,
    max_tokens: u32,
    spread: u32,
    prompts: Vec<String>,
    seed: u64,
    raw: Option<String>,
    completions: Option<String>,
    out: Option<String>,
}

fn parse_args() -> Config {
    let mut c = Config {
        addr: "127.0.0.1:8000".into(),
        model: "Qwen/Qwen3-0.6B".into(),
        concurrency: 0,
        duration: 30.0,
        warmup: 5.0,
        ramp: 2.0,
        max_tokens: 1024,
        spread: 300,
        prompts: vec!["Explain how a market data feed handler works.".into()],
        seed: 1,
        raw: None,
        completions: None,
        out: None,
    };
    let mut args = std::env::args().skip(1);
    let die = |msg: &str| -> ! {
        eprintln!("{msg}\n\n{USAGE}");
        std::process::exit(2)
    };
    while let Some(flag) = args.next() {
        if flag == "--help" || flag == "-h" {
            println!("{USAGE}");
            std::process::exit(0);
        }
        let Some(v) = args.next() else { die(&format!("{flag} needs a value")) };
        let num = |v: &str| v.parse::<f64>().unwrap_or_else(|_| die(&format!("bad number for {flag}: {v}")));
        match flag.as_str() {
            "--addr" => c.addr = v,
            "--model" => c.model = v,
            "--concurrency" => c.concurrency = num(&v) as usize,
            "--duration" => c.duration = num(&v),
            "--warmup" => c.warmup = num(&v),
            "--ramp" => c.ramp = num(&v),
            "--max-tokens" => c.max_tokens = num(&v) as u32,
            "--spread" => c.spread = num(&v) as u32,
            "--seed" => c.seed = num(&v) as u64,
            "--prompts" => {
                let text = std::fs::read_to_string(&v).unwrap_or_else(|e| die(&format!("{v}: {e}")));
                c.prompts = text.lines().filter(|l| !l.trim().is_empty()).map(String::from).collect();
                if c.prompts.is_empty() {
                    die(&format!("{v}: no prompts"));
                }
            }
            "--raw" => c.raw = Some(v),
            "--completions" => c.completions = Some(v),
            "--out" => c.out = Some(v),
            _ => die(&format!("unknown option {flag}")),
        }
    }
    if c.concurrency == 0 {
        die("--concurrency is required");
    }
    if c.spread >= c.max_tokens {
        die("--spread must be smaller than --max-tokens");
    }
    c
}

/// CLOCK_MONOTONIC in nanoseconds: the same clock eBPF's `ktime_get_ns` reads, so
/// client timestamps can be lined up with kernel-side probes on the same machine.
fn mono_ns() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `ts` is a valid, writable timespec.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
}

struct RawEvent {
    conn: u32,
    port: u16,
    request: u32,
    event: u32,
    t_ns: u64,
}

#[derive(Default)]
struct Stats {
    requests_ok: u64,
    requests_failed: u64,
    connects: u64,
    events: u64,
    bytes: u64,
    /// Gaps between consecutive events of one stream, in ns, from the third event on.
    gaps: Vec<u64>,
    /// The first two gaps of each stream, kept apart: they reflect stream start-up.
    early_gaps: Vec<u64>,
    ttft: Vec<u64>,
    raw: Vec<RawEvent>,
    completions: Vec<(u32, u32, u64)>,
}

/// Incremental decoder for an HTTP/1.1 chunked body carrying SSE.
/// Counts `data:` lines; it never copies or parses the payload beyond that.
struct Body {
    state: ChunkState,
    line: Vec<u8>,
    events: u32,
    done: bool,
}

enum ChunkState {
    Size { acc: u64, in_ext: bool },
    Data(u64),
    DataEnd(u8),
    Trailer,
    Finished,
}

impl Body {
    fn new() -> Self {
        Body { state: ChunkState::Size { acc: 0, in_ext: false }, line: Vec::with_capacity(512), events: 0, done: false }
    }

    fn reset(&mut self) {
        self.state = ChunkState::Size { acc: 0, in_ext: false };
        self.line.clear();
        self.events = 0;
        self.done = false;
    }

    fn finished(&self) -> bool {
        matches!(self.state, ChunkState::Finished)
    }

    fn feed(&mut self, mut buf: &[u8]) -> io::Result<()> {
        while !buf.is_empty() {
            match &mut self.state {
                ChunkState::Size { acc, in_ext } => {
                    let b = buf[0];
                    buf = &buf[1..];
                    match b {
                        b'\n' => {
                            self.state = if *acc == 0 { ChunkState::Trailer } else { ChunkState::Data(*acc) };
                        }
                        b'\r' => {}
                        b';' => *in_ext = true,
                        _ if *in_ext => {}
                        _ => {
                            let d = (b as char)
                                .to_digit(16)
                                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "bad chunk size"))?;
                            *acc = *acc * 16 + d as u64;
                        }
                    }
                }
                ChunkState::Data(left) => {
                    let n = (*left).min(buf.len() as u64) as usize;
                    *left -= n as u64;
                    if *left == 0 {
                        self.state = ChunkState::DataEnd(2);
                    }
                    let (data, rest) = buf.split_at(n);
                    buf = rest;
                    self.sse(data);
                }
                ChunkState::DataEnd(left) => {
                    let n = (*left as usize).min(buf.len());
                    *left -= n as u8;
                    buf = &buf[n..];
                    if *left == 0 {
                        self.state = ChunkState::Size { acc: 0, in_ext: false };
                    }
                }
                ChunkState::Trailer => {
                    // No trailers expected: the body ends at the next line feed.
                    match buf.iter().position(|&b| b == b'\n') {
                        Some(p) => {
                            buf = &buf[p + 1..];
                            self.state = ChunkState::Finished;
                        }
                        None => buf = &[],
                    }
                }
                ChunkState::Finished => return Ok(()),
            }
        }
        Ok(())
    }

    fn sse(&mut self, mut data: &[u8]) {
        while let Some(p) = data.iter().position(|&b| b == b'\n') {
            if self.line.is_empty() {
                self.on_line(&data[..p]);
            } else {
                self.line.extend_from_slice(&data[..p]);
                let line = std::mem::take(&mut self.line);
                self.on_line(&line);
                self.line = line;
                self.line.clear();
            }
            data = &data[p + 1..];
        }
        self.line.extend_from_slice(data);
    }

    fn on_line(&mut self, line: &[u8]) {
        if let Some(payload) = line.strip_prefix(b"data:") {
            if payload.trim_ascii_start().starts_with(b"[DONE]") {
                self.done = true;
            } else {
                self.events += 1;
            }
        }
    }
}

struct Stream<'a> {
    cfg: &'a Config,
    id: u32,
    rng: Rng,
    warm_ns: u64,
    buf: Vec<u8>,
    body: Body,
    request_no: u32,
}

impl Stream<'_> {
    fn request_bytes(&mut self) -> Vec<u8> {
        let cfg = self.cfg;
        let span = 2 * cfg.spread as u64 + 1;
        let max_tokens = cfg.max_tokens - cfg.spread + (self.rng.next() % span) as u32;
        let prompt = &cfg.prompts[(self.rng.next() % cfg.prompts.len() as u64) as usize];
        let body = format!(
            r#"{{"model":"{}","messages":[{{"role":"user","content":"{}"}}],"stream":true,"temperature":1.0,"max_tokens":{},"ignore_eos":true}}"#,
            json_escape(&cfg.model),
            json_escape(prompt),
            max_tokens
        );
        format!(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nAccept: text/event-stream\r\nContent-Length: {}\r\n\r\n{}",
            cfg.addr,
            body.len(),
            body
        )
        .into_bytes()
    }

    /// Runs requests back to back on one connection until an error.
    async fn run_connection(&mut self, stats: &mut Stats) -> io::Result<()> {
        let mut sock = TcpStream::connect(&self.cfg.addr).await?;
        sock.set_nodelay(true)?;
        let port = sock.local_addr()?.port();
        stats.connects += 1;
        loop {
            let req = self.request_bytes();
            let t_send = mono_ns();
            sock.write_all(&req).await?;

            // Response head.
            let mut len = 0;
            let head_end = loop {
                if len == self.buf.len() {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "response head too large"));
                }
                let n = sock.read(&mut self.buf[len..]).await?;
                if n == 0 {
                    return Err(io::ErrorKind::UnexpectedEof.into());
                }
                len += n;
                if let Some(p) = self.buf[..len].windows(4).position(|w| w == b"\r\n\r\n") {
                    break p + 4;
                }
            };
            let head = &self.buf[..head_end];
            if !head.starts_with(b"HTTP/1.1 200") {
                let status = String::from_utf8_lossy(&head[..head.len().min(32)]).into_owned();
                return Err(io::Error::other(format!("unexpected response: {}", status.trim_end())));
            }
            if !head.to_ascii_lowercase().windows(26).any(|w| w == b"transfer-encoding: chunked") {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "response is not chunked"));
            }

            self.body.reset();
            let mut seen = 0u32;
            let mut last_event_ns = 0u64;
            let mut t = mono_ns();
            let mut bytes = len;
            let mut pending = head_end..len;
            loop {
                self.body.feed(&self.buf[pending.clone()])?;
                let measured = t >= self.warm_ns;
                if measured {
                    stats.bytes += bytes as u64;
                }
                while seen < self.body.events {
                    if measured {
                        stats.events += 1;
                        match seen {
                            0 => stats.ttft.push(t - t_send),
                            1 | 2 => stats.early_gaps.push(t - last_event_ns),
                            _ => stats.gaps.push(t - last_event_ns),
                        }
                        if self.cfg.raw.is_some() {
                            stats.raw.push(RawEvent { conn: self.id, port, request: self.request_no, event: seen, t_ns: t });
                        }
                    }
                    last_event_ns = t;
                    seen += 1;
                }
                if self.body.finished() {
                    break;
                }
                let n = sock.read(&mut self.buf).await?;
                if n == 0 {
                    return Err(io::ErrorKind::UnexpectedEof.into());
                }
                t = mono_ns();
                bytes = n;
                pending = 0..n;
            }
            if !self.body.done {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "stream ended without [DONE]"));
            }
            stats.requests_ok += 1;
            if self.cfg.completions.is_some() {
                stats.completions.push((self.id, self.request_no, t));
            }
            self.request_no += 1;
        }
    }

    async fn run(&mut self, stats: &mut Stats) {
        loop {
            if let Err(e) = self.run_connection(stats).await {
                stats.requests_failed += 1;
                if stats.requests_failed <= 3 {
                    eprintln!("stream {}: {e}", self.id);
                }
                self.request_no += 1;
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

fn percentile(sorted: &[u64], p: f64) -> f64 {
    if sorted.is_empty() {
        return f64::NAN;
    }
    let i = ((p / 100.0 * sorted.len() as f64) as usize).min(sorted.len() - 1);
    sorted[i] as f64 / 1e6
}

fn dist(sorted: &[u64]) -> String {
    if sorted.is_empty() {
        return "null".into();
    }
    format!(
        r#"{{"p50": {:.3}, "p99": {:.3}, "p99.9": {:.3}, "max": {:.3}}}"#,
        percentile(sorted, 50.0),
        percentile(sorted, 99.0),
        percentile(sorted, 99.9),
        *sorted.last().unwrap() as f64 / 1e6
    )
}

fn main() {
    let cfg: &'static Config = Box::leak(Box::new(parse_args()));
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
    let threads = rt.metrics().num_workers();

    let start_ns = mono_ns();
    let warm_ns = start_ns + (cfg.warmup * 1e9) as u64;
    let all = rt.block_on(async {
        let deadline = tokio::time::Instant::now() + Duration::from_secs_f64(cfg.duration);
        let mut tasks = Vec::with_capacity(cfg.concurrency);
        for id in 0..cfg.concurrency {
            tasks.push(tokio::spawn(async move {
                let mut stats = Stats::default();
                let mut stream = Stream {
                    cfg,
                    id: id as u32,
                    rng: Rng(cfg.seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ (id as u64 + 1).wrapping_mul(0xD1B5_4A32_D192_ED03)),
                    warm_ns,
                    buf: vec![0; 16 * 1024],
                    body: Body::new(),
                    request_no: 0,
                };
                let offset = Duration::from_secs_f64(cfg.ramp * id as f64 / cfg.concurrency as f64);
                // Dropping `run` at the deadline keeps everything recorded so far.
                let _ = tokio::time::timeout_at(deadline, async {
                    tokio::time::sleep(offset).await;
                    stream.run(&mut stats).await
                })
                .await;
                stats
            }));
        }
        let mut all = Stats::default();
        for t in tasks {
            let s = t.await.expect("stream task");
            all.requests_ok += s.requests_ok;
            all.requests_failed += s.requests_failed;
            all.connects += s.connects;
            all.events += s.events;
            all.bytes += s.bytes;
            all.gaps.extend(s.gaps);
            all.early_gaps.extend(s.early_gaps);
            all.ttft.extend(s.ttft);
            all.raw.extend(s.raw);
            all.completions.extend(s.completions);
        }
        all
    });

    let measured_s = cfg.duration - cfg.warmup;
    let mut steady = all.gaps;
    steady.sort_unstable();
    let mut every = steady.clone();
    every.extend(&all.early_gaps);
    every.sort_unstable();
    let mut ttft = all.ttft;
    ttft.sort_unstable();

    let summary = format!(
        r#"{{
  "client": "loadgen",
  "concurrency": {},
  "threads": {},
  "duration_s": {},
  "warmup_s": {},
  "requests_completed": {},
  "requests_failed": {},
  "connects": {},
  "events_in_window": {},
  "events_per_s": {:.0},
  "bytes_per_event": {:.1},
  "chunk_gap_ms": {},
  "chunk_gap_ms_excl_first_two": {},
  "ttft_ms": {}
}}"#,
        cfg.concurrency,
        threads,
        cfg.duration,
        cfg.warmup,
        all.requests_ok,
        all.requests_failed,
        all.connects,
        all.events,
        all.events as f64 / measured_s,
        all.bytes as f64 / all.events.max(1) as f64,
        dist(&every),
        dist(&steady),
        dist(&ttft),
    );
    println!("{summary}");
    if let Some(path) = &cfg.out {
        std::fs::write(path, format!("{summary}\n")).expect("write --out");
    }
    if let Some(path) = &cfg.raw {
        use std::io::Write;
        let mut w = io::BufWriter::new(std::fs::File::create(path).expect("create --raw"));
        writeln!(w, "conn,local_port,request,event,t_mono_ns").unwrap();
        for e in &all.raw {
            writeln!(w, "{},{},{},{},{}", e.conn, e.port, e.request, e.event, e.t_ns).unwrap();
        }
    }
    if let Some(path) = &cfg.completions {
        use std::io::Write;
        let mut w = io::BufWriter::new(std::fs::File::create(path).expect("create --completions"));
        writeln!(w, "conn,request,t_mono_ns").unwrap();
        for (conn, request, timestamp) in all.completions {
            writeln!(w, "{conn},{request},{timestamp}").unwrap();
        }
        w.flush().unwrap();
    }
}
