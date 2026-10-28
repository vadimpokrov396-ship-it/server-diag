# Server-diag: diagnose a Linux or Windows server in one minute, in plain words

> Also published at [serverrental.store](https://serverrental.store/Server-diag:_diagnose_a_Linux_or_Windows_server_in_one_minute,_in_plain_words). Читать на русском: [ARTICLE_RU.md](ARTICLE_RU.md).

Server-diag is a free script that checks the health of a Linux or Windows server in about a minute and tells you in plain words what is broken and what to do about it. It only reads the system and never changes anything.

## What server-diag is for

Your server has become slow, your website sometimes fails to open, the database dies at night, or a Windows server reboots on its own. An experienced admin would spend half an hour reading logs, checking disk SMART data, memory and CPU load, and only then draw a conclusion. If you are new to this, it is hard to know where to start.

Server-diag does that first pass for you. It looks at six areas: disks, memory, CPU and temperature, crashes and reboots, services, and network. Each area gets its own traffic light. Then the script names the **main cause** of the trouble and gives you **three concrete steps**. Everything is written in everyday language: "the disk is almost full", "the server ran out of memory and Linux killed programs", "the hosting node is overloaded".

Who it helps:

- owners of VPS and dedicated servers who are not system administrators;
- people who rent a server for a website, a bot or a database and want to know whether the server itself is to blame;
- admins, as a quick first look: you can ask a client to run it and send you the finished report.

## Why it is safe: read-only

The core rule of server-diag is **change nothing**. The script:

- does not install programs or packages;
- does not restart services or the server itself;
- does not touch settings, files, startup entries or the firewall;
- only reads: system files in `/proc` and `/sys`, logs, and the output of harmless commands (`df`, `smartctl -a`, `journalctl`, `systemctl show`). On Windows it reads event logs, WMI system information, disk reliability counters and registry values.

The only file it creates is an HTML report with the results. Your data is not sent anywhere: the report stays on your server. For the network check it connects to the public addresses 1.1.1.1, 8.8.8.8 and 77.88.8.8, makes DNS queries and pings, and for the clock check it requests headers from google.com, ya.ru or Microsoft's connectivity-check server.

On Windows the script runs with `-ExecutionPolicy Bypass`. This applies to that single PowerShell run only; the system-wide security policy is not changed.

The code is open on GitHub. Both scripts are plain text, so you can read them in any editor before running them.

## What the script checks

### Disks

The script checks how much space is left on every partition. It looks at both percentages and gigabytes, so a big disk that is 86% full is not treated as an alarm: there is still plenty of free space. It looks for a partition that has switched itself to read-only mode, which is what Linux does when it finds filesystem errors. It also reads I/O errors from the kernel log and SMART, the disk's built-in self-diagnosis: bad and unreadable sectors, SSD and NVMe wear, cable errors, temperature. Software RAID arrays (mdadm, ZFS) and LVM-thin pools, where Proxmox virtual machines often live, are checked too, as is whether the disk has become a bottleneck.

On Windows the script reads disk health and reliability counters (uncorrectable errors, wear, temperature), the SMART failure prediction, the state of volumes and Storage Spaces, disk and NTFS events, and it measures disk latency.

### Memory

The script looks at how much RAM is available right now and whether the server is struggling by constantly shuffling memory into swap. It checks whether the OOM killer has fired. That is the Linux mechanism that forcibly terminates the heaviest program when memory runs out, and the script shows which processes were killed and when. On servers with ECC memory it checks memory module errors (EDAC).

On Windows it looks for "low virtual memory" events together with the programs that used the most memory at that moment, plus committed memory and paging to disk.

### CPU and temperature

CPU load is measured over a few seconds. If the server is virtual, the script checks **steal**: the time when the physical CPU is busy serving other customers of the host and your VPS has to wait. High steal means the problem is on the provider's side, not yours. On physical servers it checks temperature, throttling (the CPU slowing down because of overheating), and hardware errors of the CPU and memory (MCE, or WHEA on Windows).

### Crashes and reboots

The script looks for boots that ended without a clean shutdown. That means a power loss, a forced reset, a hang or a hardware fault. It also checks for kernel panics (from saved pstore and kdump reports), internal kernel errors, system freezes (soft lockups) and processes that hung for minutes waiting for the disk. It tells you honestly how many days of logs are available: if the journal is short, older crashes simply cannot be seen.

On Windows it finds blue screens and decodes the stop code: is the culprit a driver, memory, disk or hardware. It shows minidumps and unexpected shutdowns, and who rebooted the system and why.

### Services and programs

The script checks for failed services. Important ones (web server, database, SSH, Docker) are separated from harmless housekeeping tasks. It also looks for services that crash and restart in a loop: from outside everything seems to work, but requests are lost every time it falls over. Application crashes and Docker containers stuck in a restart loop are checked as well. On Windows it adds failed updates, a pending reboot, and the state of the built-in Defender antivirus: are the definitions updating, and is it eating the CPU.

### Network and time

The script checks that there is a gateway and internet access and that DNS (turning site names into addresses) works. It also looks for packet loss, large packets being cut off (MTU), network card errors and an overflowing connection table. A separate check covers clock accuracy. If the clock drifts, HTTPS certificates, one-time-code logins and API request signatures break.

## How to run it on Linux

1. Connect to the server over SSH: from Windows use PuTTY or Windows Terminal, from macOS and Linux use the `ssh` command.
2. Paste one command and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/vadimpokrov396-ship-it/server-diag/main/server-diag.sh | sudo bash
```

3. Wait 5 to 15 seconds. The verdict appears on screen, and an HTML report named like `server-diag-report-hostname-date.html` appears in the current folder. The script prints its path on the last line.

If you do not like piping scripts from the internet straight into a shell, download the file and read it first:

```bash
wget https://github.com/vadimpokrov396-ship-it/server-diag/releases/latest/download/server-diag-linux.sh
less server-diag-linux.sh
sudo bash server-diag-linux.sh
```

Useful options:

- `--full` runs a deeper, slower check: a longer load sample, more previous boots, and a day of journal errors;
- `--lang en` prints the verdict in English;
- `--out /path` sets where to save the report.

With curl, pass options like this: `curl -fsSL …/server-diag.sh | sudo bash -s -- --full`.

Without `sudo` the script still runs, but it cannot read SMART data and some logs. It says so in the "Notes / not checked" section.

## How to run it on Windows

1. Download the archive [server-diag-windows.zip](https://github.com/vadimpokrov396-ship-it/server-diag/releases/latest/download/server-diag-windows.zip).
2. Extract it: right-click the archive and choose "Extract All…". Do not run the files from inside the archive. If you do, the script tells you to extract it first.
3. Double-click **RUN-ME.bat**. The file ЗАПУСТИ-МЕНЯ.bat does the same thing for Russian-language Windows.
4. In the "Do you want to allow this app to make changes?" window click "Yes". Administrator rights are needed only to read SMART data and all the logs. If you click "No", a shortened check runs.

After 20 to 60 seconds the verdict appears in the window and the full report opens in your browser. A copy is saved on the Desktop. The script runs in the built-in PowerShell 5.1, so nothing needs to be installed.

If Windows shows "Windows protected your PC", click "More info" and then "Run anyway". Windows reacts this way to any `.bat` file downloaded from the internet.

## How to read the result

### The traffic light

| Colour | Meaning | What to do |
|---|---|---|
| 🟢 OK | No problems found. Next to it you see the fact the verdict is based on, for example "8.6 GB of 23 GB available". | Nothing. |
| 🟡 Warning | The server works, but there is a risk or the first signs of trouble. | Look into it within the next few days. |
| 🔴 Problem | A serious fault that already hurts or is about to. | Deal with it now. |

Above the lights there is an overall result, for example "EVERYTHING IS FINE — no serious problems found" or "A SERIOUS PROBLEM WAS FOUND".

### Main cause and confidence

If there are several findings, the script picks the main one. A cause ranks above its consequences: a failing disk matters more than a slow disk, and running out of memory matters more than the program crashes it triggered. Next to it you see the **confidence**. "High" means there is direct evidence: SMART readings, a kernel log entry or an error counter. "Medium" means the sign is indirect: for example, the journal ended without a shutdown record, but you cannot tell from it what exactly happened.

### What to do

Below the main cause come three steps in plain words. Where a command is unavoidable, it is given in full so you can copy it. Further down are "Also found" (the remaining findings, each with a first step), "Notes / not checked" (what could not be checked and why) and "Technical details" (the numbers for a specialist).

The HTML report contains the same and, in addition, the raw output of all commands. It is a single file with no external dependencies, which makes it easy to send to your hosting provider or an admin friend: it shows everything the script saw.

## Example 1: a Windows Server that runs low on memory

A real run on Windows Server 2025 (the server name is replaced):

```text
 RESULT: A SERIOUS PROBLEM WAS FOUND

 ● OK        Disks                OK - at most 59% used (fullest: C:, 31 GB free); SMART n/a (virtual)
 ● PROBLEM   Memory (RAM)         Windows ran low on memory: 14 time(s) in 30 days, 14 in the last 7 days
 ● OK        CPU & temperature    OK - 44% busy (3 s sample), 8 logical CPUs
 ● OK        Crashes & reboots    OK - no unexpected shutdowns or blue screens in 30 days; up 34d 0h
 ● WARNING   Services & programs  Programs crashed or hung in the last 7 days: chrome.exe x1, LogonUI.exe x1, ctfmon.exe x1
 ● OK        Network & time       OK - internet and DNS work, ping 5 ms, clock accurate (±0 s)

 MAIN CAUSE  (confidence: high)
   PROBLEM: Windows ran low on memory: 14 time(s) in 30 days, 14 in the last 7 days
   When memory runs out, programs crash with errors and Windows slows down badly. The biggest consumers were: chrome.exe, WindowsTerminal.exe.

 WHAT TO DO
   1) See who uses memory now: WindowsTerminal 2.7 GB, chrome 2.4 GB (46 procs), mspaint 1.6 GB (40 procs), svchost 1.2 GB (80 procs), cmd 409 MB (24 procs)
   2) Limit the hungry program (for example, max server memory for SQL Server) or look for a leak (does usage grow over time?)
   3) If the load legitimately grew, add RAM (a bigger plan) or enlarge the page file
```

How to read it. Right now there is enough memory, but over the past week Windows reported running low 14 times. The script does not present the program crashes as a separate disaster. The report says outright that they coincided with the memory shortages and were most likely caused by them. The steps are: see who is eating memory (the report lists dozens of browser and graphics-editor processes), limit the hungry program, and only then think about adding RAM.

## Example 2: a Linux VPS with a service that restarts in a loop

```text
 RESULT: 🟡 WORKING, BUT SOME THINGS NEED ATTENTION

 🟢 Disks                OK — at most 89% used (fullest: /, 11 GB free); SMART n/a (virtual)
 🟢 Memory (RAM)         OK — 8.0 GB of 11 GB available (69%), swap 42% used, no out-of-memory kills in 7 days
 🟢 CPU & temperature    OK — load 3.02 on 6 cores (CPU 26% busy), steal 0%
 🟢 Crashes & reboots    OK — no crashes seen, up 5d 8h; the journal keeps only 1d 0h, earlier events are unknown
 🟡 Services & programs  A service keeps crashing and restarting: my-app.service ×45119 (since boot)
 🟢 Network & time       OK — internet and DNS work, ping 3 ms, clock accurate (±0 s)

 MAIN CAUSE  (confidence: high)
   🟡 A service keeps crashing and restarting: my-app.service ×45119 (since boot)
   systemd restarts the service after each crash, so it "seems to work", but requests are lost during the crashes.

 WHAT TO DO
   1) See why it crashes: sudo journalctl -u my-app.service -n 80
   2) Common causes — out of memory, a config error, an unreachable database/network
   3) If the service is no longer needed, stop and disable it: sudo systemctl disable --now my-app.service
```

From outside this service "worked", yet it had crashed and restarted more than 45,000 times since boot. The script also tied it to another observation: the journal on this server holds only about a day of events, and it may well be flooded by this very service.

## Two more real findings

On a physical Proxmox server the script read disk SMART data and found a subtle problem: the disk reported 1298 cable transfer errors. That is not wear. Data was getting corrupted on its way from the disk to the controller and had to be sent again. The advice in the report is to re-run the check in a few days, and if the number keeps growing, ask the data center to replace the SATA cable or move the disk to another slot.

On a virtual machine the script noticed that the journal had broken off twice without a shutdown record and raised it to the top, with medium confidence: the log shows the machine "fell over" but not why. The first step in the report was to ask the hosting provider what happened at that time. For one of the two incidents the answer was confirmed: the physical server hosting that machine had restarted abnormally in the same minute.

## Typical findings and what to do about them

| Finding | What it means | First step |
|---|---|---|
| Disk almost full | Programs cannot write data and start failing | Find what takes the space and delete old backups and logs |
| Partition is read-only | The system found disk errors and blocked writes | Copy important data off and tell your provider |
| SMART: unreadable sectors | The disk is dying | Back up urgently and replace the disk |
| RAID degraded | One disk dropped out and there is no spare margin left | Back up and replace the failed disk |
| OOM, Linux kills processes | Not enough RAM | Find who eats memory; reduce its appetite or add RAM |
| High steal on a VPS | The provider's physical server is overloaded | Contact support, and change plan if it keeps happening |
| Overheating, throttling | Cooling cannot keep up | Ask the data center to check fans and dust |
| Blue screen (BSOD) | A driver, memory, disk or hardware fault | Update drivers and send the minidumps to a specialist |
| Unclean shutdowns | Power, reset, hang or hardware | Ask the provider and check the other items in the report |
| An important service is down | The website, database or mail is not working | Read the service log, fix the cause, start it |
| DNS does not work | The server cannot find sites by name | Set working DNS servers |
| Clock drift | Certificates, 2FA and API signatures break | Turn on time synchronization |

If everything is green but the server is still slow, run the check **right at the moment of the slowdown**. CPU, memory and disk load are measured "here and now", so you can see what is actually overloaded.


## FAQ

### How long does the check take?

On Linux usually 5 to 15 seconds, longer with `--full`. On Windows 20 to 60 seconds, since reading the event logs takes the most time.

### Do I need root or administrator rights?

The check works without them, but SMART data and some logs stay unread. The script says plainly what it could not check. For the full picture run it with `sudo` on Linux and click "Yes" in the permission prompt on Windows.

### Why are SMART and temperature not checked on a VPS?

A virtual server cannot see the physical disks and sensors; the hosting provider is responsible for them. This is normal and the script does not count it as a problem. On a VPS it checks steal instead, which shows whether your machine gets enough CPU on the physical host.

### Is this a security scanner or an antivirus?

No. Server-diag checks health and stability: disks, memory, CPU, crashes, services and network. It does not hunt for vulnerabilities or test passwords.

### Where is the report, and how do I send it to a specialist?

On Linux the report is in the folder where you ran the command, and its path is printed at the end of the output. You can download it from the server with WinSCP or FileZilla. On Windows the report is on the Desktop. Send the whole HTML file: it opens in any browser.

### What if the server does not boot at all?

The repository has separate scripts for rescue mode. If a Windows server will not boot, the provider can boot it into a Linux rescue system, and the script reads the Windows disk strictly read-only: SMART, minidumps, and 30 days of event logs.

## Links

- Project repository: [github.com/vadimpokrov396-ship-it/server-diag](https://github.com/vadimpokrov396-ship-it/server-diag)
- Release v2.0: [github.com/vadimpokrov396-ship-it/server-diag/releases/tag/v2.0](https://github.com/vadimpokrov396-ship-it/server-diag/releases/tag/v2.0)
- Download for Windows: [server-diag-windows.zip](https://github.com/vadimpokrov396-ship-it/server-diag/releases/latest/download/server-diag-windows.zip)
- Download for Linux: [server-diag-linux.sh](https://github.com/vadimpokrov396-ship-it/server-diag/releases/latest/download/server-diag-linux.sh)
- Real sample reports: [examples folder](https://github.com/vadimpokrov396-ship-it/server-diag/tree/main/examples)
