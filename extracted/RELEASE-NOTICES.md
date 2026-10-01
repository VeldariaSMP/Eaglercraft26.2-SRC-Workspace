# Release packaging notices

Package profile: Eaglercraft 26.2 u1 Normal, release-packaging-v1.

This setup JAR is assembled from the Normal patcher kit. The
embedded `SHA256SUMS` covers every extracted file except the manifest itself,
and the setup wrapper verifies the embedded archive before extraction. The
official Minecraft client JAR is excluded and remains a user-supplied input;
do not add it to this package.

All license and notice files shipped with the input kit are retained,
including `inputs/Vineflower-LICENSE.md`, `inputs/Vineflower-NOTICE.md`, and
the bundled audio-library notices. Keep those files with the package. This
notice records packaging scope and input boundaries; it is not a grant,
endorsement, or replacement for the terms applicable to any third-party or
user-supplied input.
