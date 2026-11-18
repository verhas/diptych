#!/bin/bash
#
# Makes sample Java archives for trying Diptych's jar preview by hand, and
# for its tests (DiptychTests/JarFixtures.swift holds them base64-encoded):
#
#   jars/sample.jar     modular, multi-release (Java 11 classes, Java 17 ones
#                       in META-INF/versions/17), Main-Class, Maven
#                       coordinates, signed by a made-up self-signed key
#   jars/tampered.jar   sample.jar with its manifest changed after signing
#   jars/sample.war     a web application: web.xml, a class, a library
#
#   ./make-jar-samples.sh [folder]      (default: ../test_folder/17-java)
#
# Everything is made up. It writes only into the folder given, and only the
# files named above; nothing else is touched. Needs a JDK (javac, jar,
# keytool, jarsigner) and zip.

set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-../test_folder/17-java}"

for tool in javac jar keytool jarsigner zip; do
    command -v "$tool" >/dev/null || { echo "needs $tool on the PATH" >&2; exit 1; }
done

mkdir -p "$TARGET/jars"
TARGET="$(cd "$TARGET" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

mkdir -p src/sample src17/sample out out17 meta/META-INF/maven/dev.diptych.sample/hello
cat > src/module-info.java <<'JAVA'
module dev.diptych.sample {
    requires transitive java.logging;
    requires static java.sql;
    exports sample;
    uses java.lang.Runnable;
}
JAVA
cat > src/sample/Hello.java <<'JAVA'
package sample;
public class Hello { public static void main(String[] args) { System.out.println("hello"); } }
JAVA
cat > src/sample/Util.java <<'JAVA'
package sample;
public final class Util { public static int twice(int x) { return 2 * x; } }
JAVA
cat > src17/sample/Hello.java <<'JAVA'
package sample;
public class Hello { public static void main(String[] args) { System.out.println("hello, " + Runtime.version()); } }
JAVA
javac --release 11 -d out src/module-info.java src/sample/*.java
javac --release 17 -d out17 src17/sample/Hello.java

cat > manifest.txt <<'MF'
Main-Class: sample.Hello
Multi-Release: true
Implementation-Title: Diptych sample
Implementation-Version: 1.2.3
Implementation-Vendor: Diptych Samples
Created-By: make-jar-samples.sh
MF
printf 'groupId=dev.diptych.sample\nartifactId=hello\nversion=1.2.3\n' \
    > meta/META-INF/maven/dev.diptych.sample/hello/pom.properties

jar --create --file sample.jar --manifest manifest.txt -C out . -C meta . --release 17 -C out17 .

keytool -genkeypair -alias sample -keyalg RSA -keysize 2048 -validity 3650 \
    -dname "CN=Diptych Sample Signer, O=Diptych Samples, C=HU" \
    -keystore signer.p12 -storetype PKCS12 -storepass changeit -keypass changeit 2>/dev/null
jarsigner -keystore signer.p12 -storepass changeit -sigfile SAMPLE sample.jar sample >/dev/null

# The same, with its manifest changed after it was signed.
cp sample.jar tampered.jar
mkdir tamper && (cd tamper && jar --extract --file ../sample.jar META-INF/MANIFEST.MF)
sed -i '' 's/Implementation-Version: 1.2.3/Implementation-Version: 9.9.9/' tamper/META-INF/MANIFEST.MF
(cd tamper && zip -q ../tampered.jar META-INF/MANIFEST.MF)

mkdir -p war/WEB-INF/classes war/WEB-INF/lib
cp -R out/sample war/WEB-INF/classes/
cp sample.jar war/WEB-INF/lib/hello.jar
printf '<web-app xmlns="https://jakarta.ee/xml/ns/jakartaee" version="6.0"/>\n' > war/WEB-INF/web.xml
jar --create --file sample.war -C war .

cp sample.jar tampered.jar sample.war "$TARGET/jars/"
echo "made $TARGET/jars: sample.jar tampered.jar sample.war"
