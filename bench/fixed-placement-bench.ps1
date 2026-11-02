# SMB bench on fixed physical blocks (PowerShell 7): writes into a preallocated file, reads an existing one.
# Example:
#   pwsh fixed-placement-bench.ps1 -Tag p28 -ReadRel <path of a ~2 GB file in the share> [-Key <ssh key>]
# -Key: omit to use ssh's default key / agent. The NAS needs /root/phys.sh (= fixed-placement-phys.sh).
param([string]$Tag = "run", [int]$Runs = 4, [int]$SizeMiB = 2000, [int]$Depth = 8, [switch]$NoUnbuffered, [switch]$NoZero,
      [string]$Nas = "root@192.168.7.4", [string]$Key, [string]$Share = "\\192.168.7.4\Public",
      [string]$WriteRel = "_bench\write-target.bin", [string]$WriteNas = "/DataVolume/shares/Public/_bench/write-target.bin",
      [Parameter(Mandatory)][string]$ReadRel, [string]$Out = (Join-Path ([IO.Path]::GetTempPath()) "fixed-bench"))
$ErrorActionPreference = "Stop"
$sshArgs = @("-o","BatchMode=yes")
if ($Key) { $sshArgs += @("-o","IdentitiesOnly=yes","-i",$Key) }
$sshArgs += $Nas
$wfile = Join-Path $Share $WriteRel
$rfile = Join-Path $Share $ReadRel
$out = Join-Path $Out $Tag
New-Item -ItemType Directory -Force $out | Out-Null
function Nas([string]$cmd) { & ssh.exe @sshArgs $cmd }
function CpuSnap { (Nas "head -1 /proc/stat") -split '\s+' | Select-Object -Skip 1 | ForEach-Object { [int64]$_ } }
function CpuPct($a, $b) {
  $d = 0..7 | ForEach-Object { $b[$_] - $a[$_] }; $t = ($d | Measure-Object -Sum).Sum
  [ordered]@{ user = [math]::Round(100*$d[0]/$t,1); sys = [math]::Round(100*$d[2]/$t,1); idle = [math]::Round(100*$d[3]/$t,1)
              iowait = [math]::Round(100*$d[4]/$t,1); softirq = [math]::Round(100*$d[6]/$t,1) }
}
$extCmd = "bash /root/phys.sh $WriteNas | tail -1"
$kernel = Nas "uname -r"
Nas "uname -a; cat /proc/fs/ext4/sda5/options 2>/dev/null | tr '\n' ' '; echo; cat /sys/block/sda/queue/read_ahead_kb /sys/block/sda/queue/scheduler; ethtool -c eth0 | grep -E '^(rx|tx)-(usecs|frames):'; grep -c splice /proc/`$(pgrep -o smbd)/maps" | Set-Content "$out\nas-state.txt"
$extBefore = Nas $extCmd

$chunk = 1MB
Add-Type -TypeDefinition @"
using System; using System.Buffers; using System.IO; using System.Threading.Tasks; using Microsoft.Win32.SafeHandles;
public unsafe sealed class NativeMem : MemoryManager<byte> {
  readonly byte* p; readonly int n;
  public NativeMem(IntPtr ptr, int len) { p = (byte*)ptr; n = len; }
  public override Span<byte> GetSpan() => new Span<byte>(p, n);
  public override MemoryHandle Pin(int i = 0) => new MemoryHandle(p + i);
  public override void Unpin() {}
  protected override void Dispose(bool d) {}
}
public static class Pump {
  public static unsafe IntPtr Alloc(int n) { return (IntPtr)System.Runtime.InteropServices.NativeMemory.AlignedAlloc((nuint)n, 4096); }
  public static long Run(SafeFileHandle h, Memory<byte> pool, long totalMiB, int depth, bool write) {
    const int C = 1 << 20; long next = 0, done = 0; var t = new Task<int>[depth];
    long slots = pool.Length / C;
    for (int i = 0; i < depth && next < totalMiB; i++, next++) t[i] = Issue(h, pool, next, slots, write);
    while (true) {
      int k = -1;
      for (int i = 0; i < depth; i++) if (t[i] != null) { k = i; break; }
      if (k < 0) break;
      int idx = Task.WaitAny(Array.FindAll(t, x => x != null));
      var live = Array.FindAll(t, x => x != null); var fin = live[idx];
      int n = fin.Result; done += n;
      int pos = Array.IndexOf(t, fin);
      t[pos] = (next < totalMiB && (write || n == C)) ? Issue(h, pool, next++, slots, write) : null;
    }
    return done;
  }
  static async Task<int> Issue(SafeFileHandle h, Memory<byte> pool, long blk, long slots, bool write) {
    const int C = 1 << 20; var m = pool.Slice((int)(blk % slots) * C, C);
    if (write) { await RandomAccess.WriteAsync(h, (ReadOnlyMemory<byte>)m, blk * C); return C; }
    return await RandomAccess.ReadAsync(h, m, blk * C);
  }
}
"@ -CompilerOptions "/unsafe"
# 64 MiB of random data in 4K-aligned native memory (needed for unbuffered I/O)
$pool = [Pump]::Alloc(64MB)
$rnd = New-Object byte[] (64MB); (New-Object Random 42).NextBytes($rnd)
[System.Runtime.InteropServices.Marshal]::Copy($rnd, 0, [IntPtr]$pool, $rnd.Length)

$mem = [NativeMem]::new([IntPtr]$pool, 64MB).Memory
$opts = [IO.FileOptions]::Asynchronous
if (-not $NoUnbuffered) { $opts = $opts -bor [IO.FileOptions]0x20000000 }
$results = @()
for ($i = 1; $i -le $Runs; $i++) {
  $zc = if ($NoZero) { "" } else { "fallocate -z -o 0 -l $($SizeMiB * 1MB) $WriteNas;" }
  Nas "$zc sync; echo 3 > /proc/sys/vm/drop_caches" | Out-Null
  $c0 = CpuSnap; $sw = [Diagnostics.Stopwatch]::StartNew()
  $h = [IO.File]::OpenHandle($wfile, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None, $opts)
  $bytes = [Pump]::Run($h, $mem, $SizeMiB, $Depth, $true); $h.Dispose(); $sw.Stop(); $c1 = CpuSnap
  $wSec = $sw.Elapsed.TotalSeconds
  $t = [Diagnostics.Stopwatch]::StartNew(); Nas "sync" | Out-Null; $t.Stop()
  Nas "echo 3 > /proc/sys/vm/drop_caches" | Out-Null
  $c2 = CpuSnap; $sw = [Diagnostics.Stopwatch]::StartNew()
  $h = [IO.File]::OpenHandle($rfile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, $opts)
  $rbytes = [Pump]::Run($h, $mem, 2040, $Depth, $false); $h.Dispose(); $sw.Stop(); $c3 = CpuSnap
  $phys = Nas $extCmd
  $r = [ordered]@{ run = $i; phys_ok = ("$phys" -eq "$extBefore"); kernel = $kernel; depth = $Depth
    write_MiB_s = [math]::Round($bytes / 1MB / $wSec, 2); sync_s = [math]::Round($t.Elapsed.TotalSeconds, 2)
    read_MiB_s = [math]::Round($rbytes / 1MB / $sw.Elapsed.TotalSeconds, 2)
    write_cpu = (CpuPct $c0 $c1); read_cpu = (CpuPct $c2 $c3) }
  $results += $r
  "{0} run{1}: write {2} MiB/s (iow {3} si {4} sys {5} idle {6}) sync {7}s | read {8} MiB/s (iow {9} idle {10})" -f $Tag, $i, $r.write_MiB_s, $r.write_cpu.iowait, $r.write_cpu.softirq, $r.write_cpu.sys, $r.write_cpu.idle, $r.sync_s, $r.read_MiB_s, $r.read_cpu.iowait, $r.read_cpu.idle
}
$extAfter = Nas $extCmd
if ("$extAfter" -ne "$extBefore") { "WARNING: write-target extents changed!" } else { "extents unchanged" }
$results | ConvertTo-Json -Depth 4 | Set-Content "$out\results.json"
