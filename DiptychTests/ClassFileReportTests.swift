import XCTest
@testable import Diptych

/// Java class files read for their outline, and the page Quick Look shows.
final class ClassFileReportTests: XCTestCase {

    // MARK: - Signatures

    func testDescriptorsReadAsSource() {
        XCTAssertEqual(JavaSignature.typeName(descriptor: "I"), "int")
        XCTAssertEqual(JavaSignature.typeName(descriptor: "[[Ljava/lang/String;"), "String[][]")
        XCTAssertEqual(JavaSignature.typeName(descriptor: "Ljava/util/Map;"), "java.util.Map")
        XCTAssertEqual(JavaSignature.typeName(descriptor: "Ljava/lang/reflect/Method;"), "java.lang.reflect.Method")
        let method = JavaSignature.method(descriptor: "(IJ[Ljava/lang/Object;)V", signature: nil)
        XCTAssertEqual(method?.parameters, ["int", "long", "Object[]"])
        XCTAssertEqual(method?.result, "void")
    }

    func testGenericSignatures() {
        let method = JavaSignature.method(
            descriptor: "(Ljava/util/Collection;)Ljava/util/List;",
            signature: "<T::Ljava/lang/Comparable<TT;>;>(Ljava/util/Collection<+TT;>;)Ljava/util/List<TT;>;")
        XCTAssertEqual(method?.typeParameters, "<T extends Comparable<T>>")
        XCTAssertEqual(method?.parameters, ["java.util.Collection<? extends T>"])
        XCTAssertEqual(method?.result, "java.util.List<T>")
        XCTAssertEqual(JavaSignature.field(descriptor: "Ljava/util/Map;",
                                           signature: "Ljava/util/Map<Ljava/lang/String;-Ljava/lang/Integer;>;"),
                       "java.util.Map<String, ? super Integer>")
        XCTAssertEqual(JavaSignature.field(descriptor: "Ljava/util/Map$Entry;",
                                           signature: "Ljava/util/Map<TK;TV;>.Entry<TK;TV;>;"),
                       "java.util.Map<K, V>.Entry<K, V>")
    }

    func testSignatureWithFewerParametersThanTheDescriptorGivesWay() {
        // An enum's constructor: the compiler adds name and ordinal.
        let method = JavaSignature.method(descriptor: "(Ljava/lang/String;ILjava/util/List;)V",
                                          signature: "(Ljava/util/List<Ljava/lang/String;>;)V")
        XCTAssertEqual(method?.parameters.count, 3)
    }

    func testParameterSlots() {
        XCTAssertEqual(JavaSignature.parameterWidths("(JI[DLjava/lang/String;D)V"), [true, false, false, false, true])
    }

    func testLiterals() {
        XCTAssertEqual(JavaSignature.quoted("a\t\"b\"\n"), #""a\t\"b\"\n""#)
        XCTAssertEqual(JavaSignature.quoted("'", quote: "'"), #"'\''"#)
    }

    // MARK: - Reading

    func testVersionAndRelease() throws {
        let modern = try ClassFile(data: ClassFileFixtures.shapes)
        XCTAssertEqual(modern.major, 65)
        XCTAssertEqual(ClassFile.release(major: modern.major), "Java 21")
        XCTAssertFalse(modern.usesPreviewFeatures)
        let old = try ClassFile(data: ClassFileFixtures.colorJava8)
        XCTAssertEqual(ClassFile.release(major: old.major), "Java 8")
        XCTAssertEqual(ClassFile.release(major: 48), "Java 1.4")
    }

    func testInterfaceOutline() throws {
        let file = try ClassFile(data: ClassFileFixtures.shapes)
        XCTAssertEqual(file.name, "sample/Shapes")
        XCTAssertEqual(file.sourceFile, "Shapes.java")
        XCTAssertNotEqual(file.access & ClassFile.Flag.interface, 0)
        XCTAssertEqual(file.permitted, ["sample/Shapes$Circle", "sample/Shapes$Square"])
        XCTAssertEqual(file.annotations.map(\.text), [#"@Deprecated(since = "2.0", forRemoval = true)"#])
        XCTAssertEqual(file.fields.first { $0.name == "NAME" }?.constantValue, #""shape\t\"x\"""#)
        XCTAssertEqual(file.fields.first { $0.name == "SIDES" }?.constantValue, "4")
    }

    func testConstantsTypedByTheirField() throws {
        let file = try ClassFile(data: ClassFileFixtures.square)
        XCTAssertEqual(file.fields.first { $0.name == "MARK" }?.constantValue, "'q'")
        XCTAssertEqual(file.fields.first { $0.name == "ON" }?.constantValue, "true")
        XCTAssertEqual(file.fields.first { $0.name == "BIG" }?.constantValue, "1234567890123L")
    }

    func testParameterNamesFromTheDebugTable() throws {
        let file = try ClassFile(data: ClassFileFixtures.square)
        let constructor = try XCTUnwrap(file.methods.first { $0.name == "<init>" })
        XCTAssertEqual(constructor.parameterNames, ["side", "more"])
        XCTAssertEqual(constructor.exceptions, ["java/io/IOException"])
    }

    func testRecordAndNesting() throws {
        let file = try ClassFile(data: ClassFileFixtures.circle)
        XCTAssertEqual(file.record?.map(\.name), ["radius", "tags"])
        XCTAssertEqual(file.nestHost, "sample/Shapes")
    }

    func testModule() throws {
        let module = try XCTUnwrap(try ClassFile(data: ClassFileFixtures.module).module)
        XCTAssertEqual(module.name, "sample.mod")
        XCTAssertEqual(module.exports.map(\.package), ["sample"])
        XCTAssertEqual(module.opens.first?.to, ["java.logging"])
        XCTAssertEqual(module.uses, ["java/lang/Runnable"])
    }

    func testMachOUniversalIsNotAClass() {
        // A universal binary: CAFEBABE, then two architectures.
        let fat = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])
        XCTAssertFalse(ClassFile.looksLikeClass(fat))
        XCTAssertTrue(ClassFile.looksLikeClass(ClassFileFixtures.color))
    }

    func testCutShortIsSaidSo() {
        let cut = ClassFileFixtures.shapes.prefix(300)
        XCTAssertThrowsError(try ClassFile(data: cut))
        let page = ClassFileReport.html(for: cut, name: "Shapes.class", path: "/tmp")
        XCTAssertTrue(page.contains("does not read as one"))
        XCTAssertTrue(page.contains("ends early"))
    }

    // MARK: - Page

    func testInterfacePage() {
        let page = ClassFileReport.html(for: ClassFileFixtures.shapes, name: "Shapes.class", path: "/tmp")
        XCTAssertTrue(page.contains("Java class file for Java 21 (class-file version 65.0)"))
        XCTAssertTrue(page.contains("compiled from Shapes.java"))
        XCTAssertTrue(page.contains("<span class=kw>public sealed interface</span> <b>Shapes</b>"))
        XCTAssertTrue(page.contains("<span class=kw>permits</span> sample.Shapes$Circle, sample.Shapes$Square"))
        XCTAssertTrue(page.contains("<span class=kw>default</span> <span class=type>String</span> <b>describe</b>()"))
        XCTAssertTrue(page.contains("&lt;T extends Comparable&lt;T&gt;&gt; <span class=type>java.util.List&lt;T&gt;</span> <b>sorted</b>"))
        XCTAssertTrue(page.contains("<b>SIDES</b> = <span class=lit>4</span>"))
        XCTAssertFalse(page.contains("<span class=kw>public static final</span> <span class=type>int</span>"),
                       "an interface's fields are written without public static final")
    }

    func testClassPage() {
        let page = ClassFileReport.html(for: ClassFileFixtures.square, name: "Shapes$Square.class", path: "/tmp")
        XCTAssertTrue(page.contains("<span class=kw>public static final class</span> <b>Square</b>"))
        XCTAssertTrue(page.contains("<b>Square</b>(<span class=type>long</span> side, <span class=type>int...</span> more)"
                                    + " <span class=kw>throws</span> java.io.IOException"))
        XCTAssertTrue(page.contains("<span class=kw>protected volatile transient</span> "
                                    + "<span class=type>java.util.Map&lt;String, ? super Integer&gt;</span> <b>cache</b>"))
        XCTAssertTrue(page.contains("Nested in <code>sample.Shapes</code>"))
    }

    func testRecordPage() {
        let page = ClassFileReport.html(for: ClassFileFixtures.circle, name: "Shapes$Circle.class", path: "/tmp")
        XCTAssertTrue(page.contains("<span class=kw>public static record</span> <b>Circle</b>(double radius, "
                                    + "java.util.List&lt;String&gt; tags) <span class=kw>implements</span> sample.Shapes"))
    }

    func testEnumPage() {
        let page = ClassFileReport.html(for: ClassFileFixtures.color, name: "Color.class", path: "/tmp")
        XCTAssertTrue(page.contains("<span class=kw>public enum</span> <b>Color</b></div>"),
                      "an enum does not say it extends Enum")
        XCTAssertTrue(page.contains("<h2>Constants <span class=count>3</span></h2>"))
        XCTAssertTrue(page.contains("Made by the Compiler"), "the lambda body is folded away")
        XCTAssertTrue(page.contains("&quot;lambda&quot;"), "strings in the code are listed")
    }

    func testModulePage() {
        let page = ClassFileReport.html(for: ClassFileFixtures.module, name: "module-info.class", path: "/tmp")
        XCTAssertTrue(page.contains("<span class=kw>module</span> <b>sample.mod</b>"))
        XCTAssertTrue(page.contains("<span class=kw>requires transitive</span> java.logging;"))
        XCTAssertTrue(page.contains("<span class=kw>requires static</span> java.sql;"))
        XCTAssertTrue(page.contains("<span class=kw>opens</span> sample <span class=kw>to</span> java.logging;"))
        XCTAssertFalse(page.contains("java.base"), "the requires every module has is not written")
    }
}
