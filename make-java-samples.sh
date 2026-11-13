#!/bin/bash
#
# Makes sample Java files for trying Diptych's previews by hand: key stores
# of every kind it reads, an enterprise archive, and compiled classes.
#
#   ./make-java-samples.sh [folder]      (default: ../test_folder/17-java)
#
# Everything is made up: a "Diptych Sample CA" that signs a certificate for
# server.example.com, and an EC key whose certificate has already expired.
# It writes only into the folder given, and only the files named below;
# nothing is deleted. Needs a JDK (keytool, javac, jar) and openssl.
#
# The key stores, and their passwords:
#   keystores/sample.jks          JKS, changeit (Java's default)
#   keystores/sample.keystore     JCEKS, sample-pass, with an AES secret key too
#   keystores/sample.p12          PKCS#12 as keytool writes it, changeit
#   keystores/sample-locked.p12   PKCS#12, sample-pass
#   keystores/sample-open.p12     PKCS#12 with unencrypted certificates, no MAC
#   keystores/sample-legacy.pfx   PKCS#12 from openssl -legacy, empty password

set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-../test_folder/17-java}"

for tool in keytool javac jar openssl; do
    command -v "$tool" >/dev/null || { echo "needs $tool on the PATH" >&2; exit 1; }
done

mkdir -p "$TARGET/keystores" "$TARGET/classes"
TARGET="$(cd "$TARGET" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------------ key stores
K="keytool -J-Duser.language=en"
quiet() { "$@" >/dev/null 2>&1; }
cd "$WORK"
quiet $K -genkeypair -alias sample-ca -keyalg RSA -keysize 2048 \
    -dname "CN=Diptych Sample CA, O=Diptych Samples, C=HU" -ext bc:c -validity 3650 \
    -storetype PKCS12 -keystore ca.p12 -storepass changeit
quiet $K -exportcert -rfc -alias sample-ca -keystore ca.p12 -storepass changeit -file ca.pem

store() { # type, file, password, then any JVM options for keytool
    local type=$1 file=$2 pass=$3; shift 3
    quiet $K "$@" -importcert -noprompt -trustcacerts -alias sample-ca -file ca.pem \
        -storetype "$type" -keystore "$file" -storepass "$pass"
    quiet $K "$@" -genkeypair -alias server -keyalg RSA -keysize 2048 \
        -dname "CN=server.example.com, OU=Web, O=Diptych Samples, L=Budapest, C=HU" -validity 825 \
        -storetype "$type" -keystore "$file" -storepass "$pass" -keypass "$pass"
    quiet $K "$@" -certreq -alias server -storetype "$type" -keystore "$file" -storepass "$pass" -file server.csr
    quiet $K -gencert -alias sample-ca -keystore ca.p12 -storepass changeit -infile server.csr \
        -outfile server.pem -rfc -ext san=dns:server.example.com,dns:localhost -validity 825
    quiet $K "$@" -importcert -noprompt -alias server -file server.pem \
        -storetype "$type" -keystore "$file" -storepass "$pass"
    quiet $K "$@" -genkeypair -alias expired-ec -keyalg EC -groupname secp256r1 \
        -dname "CN=Expired Sample, O=Diptych Samples" -startdate -800d -validity 365 \
        -storetype "$type" -keystore "$file" -storepass "$pass" -keypass "$pass"
}
store JKS sample.jks changeit
store JCEKS sample.keystore sample-pass
quiet $K -genseckey -alias api-secret -keyalg AES -keysize 256 -storetype JCEKS \
    -keystore sample.keystore -storepass sample-pass -keypass sample-pass
store PKCS12 sample.p12 changeit
store PKCS12 sample-locked.p12 sample-pass
store PKCS12 sample-open.p12 changeit \
    -J-Dkeystore.pkcs12.certProtectionAlgorithm=NONE -J-Dkeystore.pkcs12.macAlgorithm=NONE
openssl pkcs12 -in sample.p12 -passin pass:changeit -nodes -out all.pem 2>/dev/null
openssl pkcs12 -export -legacy -in all.pem -name server -passout pass: -out sample-legacy.pfx
cp sample.jks sample.keystore sample.p12 sample-locked.p12 sample-open.p12 sample-legacy.pfx "$TARGET/keystores/"

# ------------------------------------------------------------------- classes
mkdir -p src/sample out
cat > src/sample/Shapes.java <<'JAVA'
package sample;

import java.io.IOException;
import java.util.*;
import java.util.function.Function;

@Deprecated(since = "2.0", forRemoval = true)
public sealed interface Shapes permits Shapes.Circle, Shapes.Square {
    int SIDES = 4;
    String NAME = "shape\t\"x\"";
    double area();
    default String describe() { return "area " + area(); }
    static <T extends Comparable<T>> List<T> sorted(Collection<? extends T> items) { return new ArrayList<>(items); }

    record Circle(double radius, List<String> tags) implements Shapes {
        public double area() { return Math.PI * radius * radius; }
    }
    final class Square implements Shapes {
        private final long side;
        protected transient volatile Map<String, ? super Integer> cache;
        public Square(long side, int... more) throws IOException { this.side = side; }
        public double area() { return side * side; }
        private <R> R apply(Function<? super Square, R> f) { return f.apply(this); }
        public static final char MARK = 'q';
        public static final boolean ON = true;
        public static final long BIG = 1234567890123L;
    }
}
JAVA
cat > src/sample/Color.java <<'JAVA'
package sample;
public enum Color { RED, GREEN, BLUE;
    Runnable r = () -> System.out.println("lambda");
    public static Color first() { return RED; } }
JAVA
cat > src/sample/Greeter.java <<'JAVA'
package sample;
/** A bean the web module of the sample archive would call. */
public class Greeter {
    public String greet(String name) { return "Hello, " + name; }
}
JAVA
cat > src/module-info.java <<'JAVA'
module sample.mod {
    requires transitive java.logging;
    requires static java.sql;
    exports sample;
    opens sample to java.logging;
    uses java.lang.Runnable;
}
JAVA
javac -g -d out --release 21 src/module-info.java src/sample/*.java
cp out/module-info.class out/sample/*.class "$TARGET/classes/"

# ------------------------------------------------------- enterprise archive
mkdir -p ejb web/WEB-INF ear/META-INF
cp -R out/sample ejb/
jar --create --file ear/sample-ejb.jar -C ejb .
cat > web/WEB-INF/web.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="https://jakarta.ee/xml/ns/jakartaee" version="6.0">
  <display-name>Sample Web</display-name>
</web-app>
XML
echo '<!doctype html><title>Sample</title><p>Hello from the sample web module.' > web/index.html
jar --create --file ear/sample-web.war -C web .
cat > ear/META-INF/application.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<application xmlns="https://jakarta.ee/xml/ns/jakartaee" version="10">
  <display-name>Diptych Sample Application</display-name>
  <module><ejb>sample-ejb.jar</ejb></module>
  <module><web><web-uri>sample-web.war</web-uri><context-root>/sample</context-root></web></module>
</application>
XML
jar --create --file "$TARGET/sample.ear" -C ear .
cp ear/sample-web.war ear/sample-ejb.jar "$TARGET/"

echo "Made in $TARGET:"
(cd "$TARGET" && find . -type f | sort)
