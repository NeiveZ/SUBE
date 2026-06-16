# SUBE

> Subdomain Enumerator — passive-first enumeration with intelligent fallback to brute force.

![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Kali-557C94?style=flat-square&logo=kalilinux&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)
![Status](https://img.shields.io/badge/Status-Active-brightgreen?style=flat-square)

---

## Overview

SUBE enumerates subdomains using a **priority chain**: it starts with passive and stealthy techniques before escalating to active brute force. Brute force is only triggered when passive results fall below a configurable threshold — keeping reconnaissance discreet by default.

```
AXFR (Zone Transfer) → crt.sh (Certificate Logs) → Brute Force (SecLists)
```

---

## Features

- **Priority chain** — passive-first, active only when needed
- **Zone transfer (AXFR)** — attempts against all nameservers, displays records by type
- **Certificate transparency (crt.sh)** — extracts subdomains from CT logs with no active probing
- **Brute force fallback** — parallel DNS resolution using SecLists Top 100K or a local wordlist
- **Configurable threshold** — set how many passive results are "enough" before skipping brute force
- **Local wordlist support** — use any local file instead of downloading SecLists
- **Deduplication** — all sources merged and deduplicated in the final output
- **Silent mode** — plain subdomain list for piping into other tools
- **Unique temp dirs** — safe for multiple parallel executions against different domains

---

## Requirements

| Dependency | Purpose | Install |
|---|---|---|
| `bash 4.0+` | Script runtime | Pre-installed on Linux |
| `host` | DNS queries and AXFR | `apt install dnsutils` |
| `curl` | crt.sh and wordlist download | `apt install curl` |
| `awk`, `sort` | Output parsing | Pre-installed on Linux |

```bash
sudo apt install dnsutils curl
```

---

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/NeiveZ/SUBE.git
cd SUBE
```

### 2. Make the script executable

```bash
chmod +x sube.sh
```

### 3. (Optional) Install globally

```bash
sudo cp sube.sh /usr/local/bin/sube
```

---

## Usage

```
./sube.sh -d <domain> [options]

Options:
  -d, --domain          Target domain (required)
  -o, --output          Output directory (default: <domain>.out)
  -w, --wordlist        Local wordlist for brute force (default: download SecLists)
  -t, --threads         Brute force parallel threads (default: 40)
  -m, --min-passive     Min passive results to skip brute force (default: 5)
  -T, --timeout         curl timeout in seconds (default: 15)
  --passive-only        Run AXFR + crt.sh only, skip brute force
  --no-axfr             Skip zone transfer attempt
  --silent              Results only — no progress output
  -h, --help            Show this help
```

---

## Examples

**Basic scan:**
```bash
./sube.sh -d example.com
```

**Passive only — no brute force:**
```bash
./sube.sh -d example.com --passive-only
```

**Skip AXFR, go straight to crt.sh + brute force:**
```bash
./sube.sh -d example.com --no-axfr
```

**Use a local wordlist, 80 threads:**
```bash
./sube.sh -d example.com -w /usr/share/seclists/Discovery/DNS/common.txt -t 80
```

**Raise the passive threshold (needs 20 passive results before skipping brute force):**
```bash
./sube.sh -d example.com -m 20
```

**Silent mode — pipe results into other tools:**
```bash
./sube.sh -d example.com --silent | tee subdomains.txt
./sube.sh -d example.com --silent | httpx -silent
./sube.sh -d example.com --no-axfr --silent | dnsx -silent
```

**Save to custom directory:**
```bash
./sube.sh -d example.com -o /tmp/engagement/example
```

---

## How the Priority Chain Works

```
┌─────────────────────────────────────────────────────────┐
│  1. AXFR — attempt zone transfer on all nameservers     │
│     ↓ always continues to step 2                        │
│  2. crt.sh — query certificate transparency logs        │
│     ↓ count passive results (AXFR + crt.sh)             │
│     ┌──────────────────────────────────────────┐        │
│     │ results ≥ MIN_PASSIVE?                   │        │
│     │  YES → skip brute force, print results   │        │
│     │  NO  → run brute force                   │        │
│     └──────────────────────────────────────────┘        │
│  3. Brute Force — parallel DNS resolution via wordlist  │
│  4. Merge + deduplicate all sources → final output      │
└─────────────────────────────────────────────────────────┘
```

---

## Output

```
example.com  chain: AXFR → crt.sh → Brute Force
min-passive: 5  threads: 40  passive-only: false

[*] Step 1/3 — Zone transfer attempt (AXFR)
[!] Zone transfer failed or not permitted
[*] Step 2/3 — Passive enumeration via crt.sh
[+] crt.sh returned 3 unique subdomain(s)
[!] Passive results (3) below threshold (5). Starting brute force...
[*] Step 3/3 — Active brute force
[>] mail.example.com
[>] api.example.com
[>] dev.example.com
[>] staging.example.com

[+] Total unique subdomains: 7
[*] Saved to: example.com.out/example.com-subdomains.txt

[*] Sample results:
  api.example.com
  dev.example.com
  mail.example.com
  ...

time: 42s
```

Results are saved to `<domain>.out/<domain>-subdomains.txt` by default.

---

## Repository Structure

```
SUBE/
└── sube.sh    # Main script
```

---

## Legal

For use only on systems you own or have explicit written authorization to test.
Unauthorized use against third-party systems is illegal.
