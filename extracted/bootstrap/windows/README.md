# Windows x64 app-local toolchain

Run `bootstrap/windows/eagler-patcher-windows-x86_64.cmd` from the package. It installs Java 17,
Java 25, Node.js 24 LTS, and npm under the package's `.toolchain` directory,
then launches `eaglercraft-26.2-u1-patcher-gui.jar` with app-local Java 17.
The GUI reads `java17`, `java25`, `node`, and `npm` from the adjacent UTF-8
`toolchain.properties`; `npm` points to Node's `npm-cli.js`.

Supported systems are 64-bit Windows 10 (22H2, build 19045) or Windows 11 on
x64, with 64-bit Windows PowerShell 5.1 or newer, an unelevated session, and
a writable local-drive package directory. The script does not support Windows
ARM64, 32-bit Windows or PowerShell, Windows versions before 10, UNC/network
locations, macOS, or Linux. It rejects an elevated Administrator token and
makes no system-wide environment changes. It applies PowerShell's
`Bypass` policy to its child process only; it does not change the user's saved
execution policy.

The bootstrap downloads current x64 ZIP archives from Eclipse Adoptium
API/release host and nodejs.org over HTTPS. It checks each Java API digest
against the official release sidecar, checks Node against the official
`SHASUMS256.txt`, verifies the downloaded bytes, rejects unsafe ZIP paths and
link entries, checks `java`, `javac`, `node`, and `npm-cli.js`, then atomically
publishes `toolchain.properties`. Concurrent runs serialize on
`.toolchain/.bootstrap.lock`. A later run reuses a manifest only after checking
that all four paths remain within `.toolchain` and their tools report the
expected major versions.

The first install needs an internet connection and several hundred megabytes
of temporary and installed space. It writes only under the package directory:
`.toolchain`, `toolchain.properties`, and temporary manifest/write-check files
beside them (removed when the operation finishes). Put the package in a user-writable
location such as Downloads or a user-owned applications folder; do not place it
under Windows, Program Files, or ProgramData. A failed download/check does not
publish or replace a manifest. The bootstrap may leave verified tool directories if a
later manifest write fails; a retry validates and reuses those versioned
directories.

This installs Java and Node/npm only. It does not fetch the user-supplied
official Minecraft 26.2 JAR or the authenticated Vineflower, patch bundle,
project skeleton, resource overlay, external resources, or sound input.

## Offline test

On a supported non-administrator Windows x64 PowerShell session, run:

```powershell
.\test-bootstrap-windows.ps1
```

The test creates local mock ZIPs and vendor metadata in a temporary folder; it
does not access the network or download real tool archives. It stubs only the
process version probes because synthetic fixture executables cannot run as
Windows PE binaries. It checks app-local publication, cache reuse, lock
exclusivity, checksum rejection, and path traversal rejection.
