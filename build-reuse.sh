cd extracted

JAVA17=/usr/local/sdkman/candidates/java/17.0.13-tem/bin/java
JAVA25=/usr/local/sdkman/candidates/java/25-tem/bin/java

java -jar eaglercraft-26.2-java-cli.jar build-standalone \
  --jar ./client.jar \
  --output ../eagler-26.2-workspace \
  --vineflower ./vineflower-1.12.0.jar \
  --java17 "$JAVA17" \
  --java25 "$JAVA25" \
  --node "$(which node)" \
  --npm "$(which npm)" \
  --patch-bundle ./source-patch-bundle.zip \
  --expected-bundle-sha256 fd944e9cabbebbf4bddce8a39e1b233b3c7d0cd4f860f9cae37550a3fcfa8b02 \
  --project-skeleton ./project-skeleton-v5-teavm-runtime-verified.zip \
  --expected-skeleton-sha256 3656a83ed8187e2d859612c566f3aa73e242bf1e4633990c5bb4929e0a846c94 \
  --resource-overlay ./inputs/resource-overlay-normal.zip \
  --expected-resource-overlay-sha256 2ba7e3376891c64f8bf57f3687e05b8dbe1971a75475b6825449e5e5f96d71f3 \
  --external-resource-root ./inputs/resources \
  --sounds-epk ./inputs/sounds.epk \
  --expected-sounds-epk-sha256 94bc8bfcf4132c52c6d5f61f3f92e50532a6fad1f5bc901ee25a462db8ba4fc6 \
  --music-epk ./inputs/music.epk \
  --expected-music-epk-sha256 f01cdaf62a9686438998b11ffed5407a1b890e14960c63f71b57401d02216a4e \
  --standalone-output ../eagler-26.2-standalone.html \
  --reuse-project