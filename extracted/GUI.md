# Desktop launcher

Open `eaglercraft-26.2-u1-patcher-gui.jar` with Java, or run
`./eagler-patcher-gui` or `eagler-patcher-gui.cmd` on Windows beside the
patcher JAR. The launcher needs Java 17 or newer with Swing. If the JAR is
only in `build/`, the Unix wrapper rebuilds the launcher JAR from the checked-out source.

The Windows wrapper deliberately requires the prebuilt JAR beside it; it does
not attempt to run a Unix build script.

With the complete Setup JAR, choose an installation folder once. It unpacks the
build files itself. Then choose your Minecraft JAR, project folder and output.
No bundle ZIP or EPK selection is needed. Build rechecks the bundled files and
repairs missing paths; readable custom paths in Advanced stay unchanged.

Choose an output:

1. Source project runs `create-dev`. Without a resource overlay and external
   resource root, it creates patched source and project files, but not a
   complete buildable game workspace.
2. Standalone HTML runs `build-standalone`. The packaged kit finds adjacent
   bundle, skeleton, overlay, and audio files when included. Choose the official client JAR,
   project folder, and HTML output; install build tools if prompted.
   The command creates patched source before building the HTML, so you do not
   need to run Source project first. To use a project created earlier, choose
   its folder; reuse is automatic. The CLI checks its receipt and required
   files. This option is only available for Standalone HTML; the CLI rejects
   arbitrary non-empty folders.
3. Isolated Web App runs `build-iwa`. It builds the patched client and signs a
   local `.swbn` from that same build. The mode exposes the IWA output and
   signing-key paths; keep the private key to preserve the app identity for
   later builds. An optional HTML path creates a browser-test HTML and its
   music resource-pack ZIP from the same compile. The IWA mode does not accept
   the optional Wispcraft script or standalone music options.

The GUI converts file inputs to absolute paths before passing them to the CLI;
it passes SHA-256 values unchanged. It checks that required files exist and
that supplied SHA-256 fields contain 64 lowercase hex characters.
The source-bundle hash is filled from the CLI's accepted pin. Selecting a skeleton
fills its accepted hash too, so these two hashes do not need to be copied by hand.
The accepted resource-overlay hash is filled when the conventional local overlay
is found. A local `sounds.epk.sha256` file beside `sounds.epk` can supply its
SHA-256; otherwise the user enters it. The CLI checks the actual sounds bytes.
After the window opens, the GUI checks the local install for Java 17, Java 25,
Node 20+, and npm's `npm-cli.js`. The CLI requires Java 17 and records its
runtime hashes; it verifies the exact decompiled-source manifest before patching.
When an app-local bootstrap has written `toolchain.properties` beside the GUI
JAR, those paths are checked first; installed system tools remain the fallback.
The client JAR, Vineflower, source bundle, skeleton, resource overlay, and sounds
remain subject to the CLI's existing checks.

The GUI looks for conventional input names beside the patcher JAR, in the
current directory, or in `inputs/`: the client JAR,
`vineflower-1.12.0.jar`, source bundle, verified v5 skeleton, resource overlay,
`resources/` external root, `sounds.epk`, and `music.epk`. This only fills
paths. The CLI checks the accepted pins and archive contents. Project,
standalone HTML, IWA bundle, and
signing-key destinations start blank; choose or enter the paths you want.
When the key path is blank, the CLI keeps the key under the selected project.
Its PROGRESS lines select the current stage. The window shows a live elapsed
timer and an indeterminate bar while a stage has no measurable sub-steps.
Cancel terminates the child JVM and uses a forcible fallback after two seconds.
After a successful run, **Open folder** opens the generated project for Source
project, or the output file's parent folder for Standalone HTML and IWA.

The window reports the detected build-memory budget. Current Wasm builds need
at least 10 GiB for the build, plus memory reserved for the OS; a
16 GiB machine is typically the practical minimum. The CLI rechecks capacity
before compiling and refuses an insufficient budget rather than risking an OOM.
Less memory can make the build slower and does not guarantee completion.

Allow about 30 minutes on a reasonably capable PC, based on the maintainer's
experience. Slower hardware, dependency downloads, and memory pressure can add
time. The GUI shows elapsed time, not a countdown.

In Standalone mode, the smaller output creates a music resource-pack ZIP beside
the HTML. Import the ZIP through the game's resource-pack screen; the HTML
does not load a sibling ZIP automatically. The larger output embeds music.
Advanced options can inject a locally supplied Wispcraft `dist/index.js` into
the HTML. No Wispcraft script is included or downloaded.

The IWA is a local Signed Web Bundle for Chrome's Isolated Web App installation
flow. It is not an executable or hosted download. See `iwa/README.md`
for the Chrome installation steps, the user-controlled IWA flags, and the
separate limits of the local browser checks. The patcher keeps the private
signing key at the selected local path; do not share it.

The **Content profile** selector offers **Normal** in Source project,
Standalone HTML, and Isolated Web App modes. The patcher does not include the
official Minecraft client JAR. This release package includes the Normal build
inputs and audio archives used by its workflow; see `START-HERE.md` and
`RELEASE-NOTICES.md`, and keep all notices with the package. Java and Node are
installed separately by the launcher when needed.

For a quick compile and wiring check:

    ./build.sh
    ./eagler-patcher-gui --self-test
