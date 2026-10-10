import Foundation

/// The cameras and lenses Diptych comes with, spelt as they write
/// themselves into a picture's EXIF -- `NIKON CORPORATION` and `NIKON Z 6_2`,
/// not the names on the box. What Control-Space offers in the EXIF editor's
/// Camera Make, Camera Model, Lens Make and Lens Model, once merged into
/// `~/.diptych/exif/cameras.json` and `lenses.json`, where a wrong one can be
/// disabled and a missing one added.
nonisolated enum ExifGearList {

    static let cameras: [ExifDatabase.Gear] = gear([
        ("Apple", [
            "iPhone 6", "iPhone 6s", "iPhone 7", "iPhone 7 Plus", "iPhone 8", "iPhone 8 Plus",
            "iPhone X", "iPhone XR", "iPhone XS", "iPhone XS Max",
            "iPhone 11", "iPhone 11 Pro", "iPhone 11 Pro Max", "iPhone SE (2nd generation)",
            "iPhone 12 mini", "iPhone 12", "iPhone 12 Pro", "iPhone 12 Pro Max",
            "iPhone 13 mini", "iPhone 13", "iPhone 13 Pro", "iPhone 13 Pro Max",
            "iPhone SE (3rd generation)",
            "iPhone 14", "iPhone 14 Plus", "iPhone 14 Pro", "iPhone 14 Pro Max",
            "iPhone 15", "iPhone 15 Plus", "iPhone 15 Pro", "iPhone 15 Pro Max",
            "iPhone 16", "iPhone 16 Plus", "iPhone 16 Pro", "iPhone 16 Pro Max", "iPhone 16e",
            "iPhone 17", "iPhone 17 Pro", "iPhone 17 Pro Max", "iPhone Air",
        ]),
        ("Canon", [
            "Canon EOS 5D Mark II", "Canon EOS 5D Mark III", "Canon EOS 5D Mark IV",
            "Canon EOS 6D", "Canon EOS 6D Mark II", "Canon EOS 7D", "Canon EOS 7D Mark II",
            "Canon EOS 80D", "Canon EOS 90D", "Canon EOS 250D", "Canon EOS 2000D",
            "Canon EOS-1D X Mark II", "Canon EOS-1D X Mark III",
            "Canon EOS R", "Canon EOS RP", "Canon EOS R3", "Canon EOS R5", "Canon EOS R6",
            "Canon EOS R6m2", "Canon EOS R7", "Canon EOS R8", "Canon EOS R10", "Canon EOS R50",
            "Canon EOS M50", "Canon EOS M6 Mark II",
            "Canon PowerShot G7 X Mark II", "Canon PowerShot G7 X Mark III",
        ]),
        ("NIKON CORPORATION", [
            "NIKON D500", "NIKON D610", "NIKON D750", "NIKON D780", "NIKON D810", "NIKON D850",
            "NIKON D3500", "NIKON D5600", "NIKON D7200", "NIKON D7500", "NIKON D6",
            "NIKON Z 5", "NIKON Z 6", "NIKON Z 6_2", "NIKON Z 6_3", "NIKON Z 7", "NIKON Z 7_2",
            "NIKON Z 8", "NIKON Z 9", "NIKON Z 30", "NIKON Z 50", "NIKON Z fc", "NIKON Z f",
        ]),
        ("SONY", [
            "ILCE-1", "ILCE-9", "ILCE-7M3", "ILCE-7M4", "ILCE-7RM3", "ILCE-7RM4", "ILCE-7RM5",
            "ILCE-7SM3", "ILCE-7C", "ILCE-7CM2", "ILCE-6000", "ILCE-6100", "ILCE-6400",
            "ILCE-6600", "ILCE-6700", "ZV-1", "ZV-E10",
            "DSC-RX100M6", "DSC-RX100M7", "DSC-RX10M4",
        ]),
        ("FUJIFILM", [
            "X-T3", "X-T4", "X-T5", "X-T30", "X-T30 II", "X-S10", "X-S20", "X-H2", "X-H2S",
            "X-E4", "X-Pro3", "X100F", "X100V", "X100VI", "GFX 50S", "GFX100S",
        ]),
        ("Panasonic", [
            "DC-GH5", "DC-GH6", "DC-G9", "DC-G9M2", "DC-GX9", "DC-S5", "DC-S5M2", "DC-TZ90",
        ]),
        ("OLYMPUS CORPORATION", [
            "E-M1MarkII", "E-M1MarkIII", "E-M5MarkII", "E-M5MarkIII", "E-M10MarkIII",
            "E-M10MarkIV", "PEN-F", "TG-6",
        ]),
        ("OM Digital Solutions", ["OM-1", "OM-1MarkII", "OM-5", "TG-7"]),
        ("LEICA CAMERA AG", ["LEICA Q2", "LEICA Q3", "LEICA M10", "LEICA M11", "LEICA SL2"]),
        ("RICOH IMAGING COMPANY, LTD.", [
            "RICOH GR III", "RICOH GR IIIx", "PENTAX K-1 Mark II", "PENTAX K-3 Mark III",
            "PENTAX KP",
        ]),
        ("Hasselblad", ["X1D II 50C", "X2D 100C"]),
        ("samsung", [
            "SM-G991B", "SM-G996B", "SM-G998B", "SM-S901B", "SM-S906B", "SM-S908B",
            "SM-S911B", "SM-S916B", "SM-S918B", "SM-S921B", "SM-S926B", "SM-S928B",
            "SM-A525F", "SM-A536B", "SM-A546B", "SM-A556B",
        ]),
        ("Google", [
            "Pixel 4a", "Pixel 5", "Pixel 6", "Pixel 6 Pro", "Pixel 6a", "Pixel 7",
            "Pixel 7 Pro", "Pixel 7a", "Pixel 8", "Pixel 8 Pro", "Pixel 8a", "Pixel 9",
            "Pixel 9 Pro", "Pixel 9 Pro XL", "Pixel 9a", "Pixel 10", "Pixel 10 Pro",
        ]),
        ("Xiaomi", ["Redmi Note 10 Pro", "Redmi Note 12", "Redmi Note 13 Pro"]),
        ("GoPro", ["HERO9 Black", "HERO10 Black", "HERO11 Black", "HERO12 Black"]),
        ("DJI", ["FC3170", "FC3411", "FC3582", "L2D-20c"]),
    ])

    static let lenses: [ExifDatabase.Gear] = gear([
        ("Apple", [
            "iPhone X back dual camera 4mm f/1.8", "iPhone X back dual camera 6mm f/2.4",
            "iPhone X front TrueDepth camera 2.87mm f/2.2",
        ]),
        ("Canon", [
            "EF 24-70mm f/2.8L II USM", "EF 24-105mm f/4L IS II USM",
            "EF 70-200mm f/2.8L IS III USM", "EF 50mm f/1.8 STM",
            "EF 100mm f/2.8L Macro IS USM", "EF-S 18-55mm f/3.5-5.6 IS STM",
            "EF-S 18-135mm f/3.5-5.6 IS USM",
            "RF15-35mm F2.8 L IS USM", "RF24-70mm F2.8 L IS USM", "RF24-105mm F4 L IS USM",
            "RF24-105mm F4-7.1 IS STM", "RF50mm F1.8 STM", "RF70-200mm F2.8 L IS USM",
            "RF100-500mm F4.5-7.1 L IS USM", "RF-S18-45mm F4.5-6.3 IS STM",
            "RF-S18-150mm F3.5-6.3 IS STM",
        ]),
        ("Nikon", [
            "NIKKOR Z 14-30mm f/4 S", "NIKKOR Z 24-70mm f/4 S", "NIKKOR Z 24-70mm f/2.8 S",
            "NIKKOR Z 24-120mm f/4 S", "NIKKOR Z 40mm f/2", "NIKKOR Z 50mm f/1.8 S",
            "NIKKOR Z 70-200mm f/2.8 VR S", "NIKKOR Z DX 16-50mm f/3.5-6.3 VR",
            "AF-S NIKKOR 24-70mm f/2.8E ED VR", "AF-S NIKKOR 50mm f/1.8G",
            "AF-S DX NIKKOR 18-140mm f/3.5-5.6G ED VR",
        ]),
        ("Sony", [
            "FE 16-35mm F2.8 GM", "FE 20-70mm F4 G", "FE 24-70mm F2.8 GM",
            "FE 24-70mm F2.8 GM II", "FE 24-105mm F4 G OSS", "FE 28-70mm F3.5-5.6 OSS",
            "FE 50mm F1.8", "FE 85mm F1.8", "FE 70-200mm F2.8 GM OSS II",
            "FE 200-600mm F5.6-6.3 G OSS", "E 18-135mm F3.5-5.6 OSS",
            "E PZ 16-50mm F3.5-5.6 OSS",
        ]),
        ("FUJIFILM", [
            "XF10-24mmF4 R OIS WR", "XF16-55mmF2.8 R LM WR", "XF16-80mmF4 R OIS WR",
            "XF18-55mmF2.8-4 R LM OIS", "XF23mmF2 R WR", "XF35mmF1.4 R", "XF56mmF1.2 R",
            "XF70-300mmF4-5.6 R LM OIS WR", "XC15-45mmF3.5-5.6 OIS PZ",
        ]),
        ("SIGMA", [
            "18-35mm F1.8 DC HSM | Art 013", "24-70mm F2.8 DG DN | Art 019",
            "35mm F1.4 DG HSM | Art 012", "100-400mm F5-6.3 DG DN OS | Contemporary 020",
        ]),
        ("TAMRON", [
            "17-70mm F/2.8 Di III-A VC RXD (Model B070)",
            "28-75mm F/2.8 Di III RXD (Model A036)",
            "28-75mm F/2.8 Di III VXD G2 (Model A063)",
            "70-180mm F/2.8 Di III VXD (Model A056)",
        ]),
        ("Panasonic", ["LUMIX G VARIO 12-60/F3.5-5.6", "LEICA DG 12-60/F2.8-4.0"]),
        ("OLYMPUS CORPORATION", [
            "OLYMPUS M.12-40mm F2.8", "OLYMPUS M.12-100mm F4.0",
            "OLYMPUS M.14-42mm F3.5-5.6 EZ",
        ]),
    ])

    private static func gear(_ makes: [(String, [String])]) -> [ExifDatabase.Gear] {
        makes.flatMap { make, models in
            models.map { ExifDatabase.Gear(make: make, model: $0) }
        }
    }
}
