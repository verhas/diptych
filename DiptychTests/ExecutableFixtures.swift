import Foundation

/// Made-up hello-world programs and libraries, compiled by
/// make-executable-samples.sh (clang, lipo, codesign; zig for Linux and
/// Windows), each kept as base64 of its raw DEFLATE: the page padding in a
/// Mach-O file compresses to nothing.
enum ExecutableFixtures {

    static func data(_ base64: String) -> Data {
        let packed = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
        return try! (packed as NSData).decompressed(using: .zlib) as Data
    }

    /// Linked by clang for arm64, macOS 13, signed by the linker.
    static let helloArm64 = data("""
        7d1LaBNBHAbw2U1aaq1ai2jF114sKrUVLVVPttpig4+KjRAUnabJxgbzKMkGWysY38+DjwrxoKAerGAvIqgHsV7Ek1rRCipaBUUp
        FQVFLLQ6s5ltJzGlgogevh8Mm9nsfDs7O8n1/6C/bzCPEIUwKmsTWdPshOwnGj9FprJWwxql6ypXVm+sXl9LfqGQ0fGcQwrPcVa7
        nBnGV6QNEP0s0eziNKWG3mwMX5aeV29P5mlSX5Vz7SQudymNGrGG6Ih5cZGXJ/XlvByRlzc03hM1Iv7Q1hHyjom86VJfpqYtA6Wx
        0HZ/yEv9IV84Q167yHNJfXWU95Awc6oqnZV0Re3aOqe13invIe1oE41fk2+O3xo2UuaZOS9Hep826frstH0zvM9WO9auqq5yWM8Y
        T5uXeHsJdXjvyDll7Ip8cV09OywS/XrWXyDWt5CPjyfn85Ad57DjWNbWkV/fhTrK/r4Xz7ze48Ue5PuiNBaNlAb8DaXeloBXfD9N
        zONtz5uibMfik6dyzx1Z+fHQ5oViXPKe41j4NPOzuXbKG/88sf4WNvd4odjnMn7fJeIefH62ObVZPHVoLqzVtUQNPViyvITNy9+Q
        HFck8o/Hk+9urugnxLrPsO6/m537jR/+QOvtywM2coJHkgUFJ9g029iU1w+03mnvtNFu9k6O56sV34k6q7tGDwTCmi8SDmpurcrf
        ZLR4GrWoO9gU0FN+M/JRFc9eIbbIbnvq9rXYzDVR2NyV4X8CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAID/UxxLAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPBvaSRZ+5yXXE+vpy4XyS5M/1yRnVJo2xzLC3LTppgRtU5SUsCPZhFy0pPDPtFgI9Wb
        dU/M0Gmj7vbqETIm6PaHeLnzHlEwnl8+Qckfyp1s9pO1vq1a4Io0VatWu0ZohnhqxsvTsvS/zOtkMQnpsSexcyxK2UdUOw/lsbxs
        u0t8P4YXP9dUs8T67y6v+RiNvL75fHckWF5GQnvGz57Sod/0vP96sHSw6t3E+W0vHXu1DYPkk3fCE8XRsevKVVf47gdfp/1pV9c2
        tdaV9WPntZ079j+7dbTmcPGlP/3+1ZPeA59P+2zni7PLv3hm+T6PG3vj8ceLjzbt6Xl7Ur3W97fvrxRd/xZ6vuXMi1x91VlnYu7S
        I7TgdbCtt26N+8L9mcsqfwI=
        """)

    /// The arm64 one and an x86_64 one for macOS 10.13, joined by lipo.
    static let helloUniversal = data("""
        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
        """)

    /// The arm64 one after codesign --remove-signature.
    static let helloUnsigned = data("""
        7d2/TxRBFMDx2b2DoKJeKAwGE7ciaAFETbQ8lAsQDRC4gpiY4eAW2OR+kLu9CKFZCxNiLEAtqKzxr1A7O62oCYml1mqCcXZ3DuaW
        IyQ2Wnw/yWR2lp23b2fmaN/nX99+dwthCcVWLRO2tBDPhRPeEldVG1dNyumRsdzj3MyUOMESZwvjbFphnHxuLt9mfjYxQY87dEvr
        21L67pp//Fgy3nw6jucYY9uMmxaBOZSy7jcW6qfGC3S8bmNsxuvS8bqP5i/W/ZpXWT4l3ksd75oxNtmJZZCyUXnqVYrSqyxV28Tb
        1fHmjLF9xj7sRHFGR/Ij8sHU5Gy+ud4t+5DoU7pZ+oxIuVz1W/JsH6/L2M+U8Xxn4twcn7NHE5MPc6MTzW8MEnnp3fthnB0zzh31
        REY/N6+623o8r8bDen17wzUI4ny+qH5A9RdUmxYn98I+43x/Ctqv9yV9BsNzMdSo14ZK3sJQcb1U1H/v03l83T/o75y4++r1+bcv
        xr5vPrml58XvvKiC90XX0dpZB95Nvf5NKvegV59zU/jee/odYX6pgamOMOpRLqrNrtd9tzx4f1Dl5S3E8/p1/K0g3rsberwTiL9y
        uPH+3WFKbIchxXDPtkrzjUp55nDj4+6HlNxTe7KVsbM/hX19b9wtlarOUq1adgrOqLfqry+uOPVCebXktvxmzN7W357VR+RZuvX4
        NqWiNbHUt1jH/wkAAAAAAAAAAAAAAAAAAAAAAAAAAACA/1PAEgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA8G85Iq59HpZcT9ZTN4tk
        9yavs50thbajuWFBbrna8OvNm1L0hH1UhFzsd6krWV6R7pq72PBdueIWim5NnCsXvEpY7nxfF4wPH79sZY7iXonGca3vZi1wy0i1
        WavdEbJNeBmFN9P6Aw==
        """)

    /// Signed ad hoc with the hardened runtime, the identifier example.diptych.hello and three entitlements.
    static let helloEntitled = data("""
        7d1bbBRVGAfwmd1tqWWB2getFuiwJQ2Y7M6KJFyy9Lq1VGq7oVusIky3u0M7ZW/szHa74cHtQw2WmhRLSEnUEC8E0z4QE69Riy/q
        i4KYNEGUYBNIhIA+EEobC56ZOUtnl9bV+KAP/18ymTnTc77zzTln+/qdnb1x18owLEOYyPUwuTgLwwwwnPqKeYxc28klCJ6ahvoX
        6ne2MA9gmdzUOIdYNY63vt27wPjqrAG0nUcvC30tCIrYp8x3y47XYdHjcYa2yRjXwqSMTUGQlXinvGi8FI1nNbSN8QpoPOv98X5Z
        iUnhrkXiDdF4Kw1tI1PWMghCPJyQwgFBCu+LLBDvFI3XbmibcuzDqBbHXeOtEepamlu96fXO2Iesu5leap8ibXxXRMnIc+F4BYb9
        NBv652edm/lz1tTYvKPe3Zj+xlRWXnT3frfMnx1jnI2kRxHt10FuT9F2B2k76fqWqGuQ0vM5R+7ryH0puTzMg3thynG+v0ktvN7L
        6RlUzwUfl2N8UOrkA8lggP69lOZx5fJURX7jptdGCt8cbLh5aM8GOk6fcxkJXqo9a2vHTklP0PVPI7mnSug5N1Ln3UznUPMzr2vJ
        U6Pez4VcrUlZEUOOWgfJS+rUx1XQ+MMpfe/W0/YoXfdV6fn7yR6Yc//u5w5OvDdnZo6oIRln8RGS5lGS8s65g1+eOmMWJsmeDBeZ
        qmcYU9nkdjEYjHD7YpEQ5+PcUlRJ+rs52ReKBsWM34zxbqLfXk2PSL8l8/immbU1YUnu7Px/AgAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAACA/6cUlgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADgv8Uxeu1zteR6dj11Y5Hskuzn6vyMQtvaWLUgtxCN
        K3L6pcAUq3etCDlzuYA8CaFuQewT/XFFFLpFX0CMMQ+FfFJYLXd+mRaMV7uvYIvux31Ea+u1vtO1wFlDqula7RwjLBBe0MIb00qb
        vWQ9QxK7QR7z6KuNeij2mv6OvU3uS0ifDn028xUyRv37h4xJK6muPu9i9HLzS7SvZPoZzqSVgP8bqueXr1SvJC/2aTXPHQG9BLqj
        W62LzpjZuvELh38b+2rw2NWyub21K2+94hm4N/nOsj2fVb++7mNnrnm+fd/WG21+yRu7fs7Sfvjz8tkXG6ZHTpjb8k9+cfsHd7n9
        356i0SQ33DwmLo/3DeU9c+L0zuae1MTXj79tv3N+08lH62ZezjX+05ELG2pH2qWZ3rtXb+7++dadX53ljeObz7e9u2vF8Pjx0tWu
        P/atWisNnTi79ZPExPfcByVTK8q3v3rxuWtjP04Pb9nNVnw0Hb649/hPheKON7yj67cMCsW/hI5eb33W99Z3q6tqyK6p+2fVd/3A
        AbLgPa6qvlCQ6xVjshQJb7M96XDaODHsjwSkcNc2W5v3aftmW1VloWuNu6XO+7ynnosGJVnhPG21TY11nM3O8zVRslM87/a6OU9T
        Y6uXIzF4vr7Zxtm6FSW6lecTiYTDp/Zy+CMhtaPMe2KRqBhTkk0kmJ0McASUgI1Mo0fPSIe8DUh+pbKQI1z7xWQliULjyeSMxyQl
        6fDLDh85Igl7j6S4eLWTS4nFRf6vR4VFJRGJ7Xf4g5IY/gfjukTFrvjk/XZtzsxxLl7P1sVr31JZSFY6RhZ8IHrQxLKne51rrWU5
        PoBl7zkrrGtyTrx4v8wPI/1mLy1Vt1791/In
        """)

    /// A dynamic library, install name @rpath/libsample.dylib, version 1.2.3, compatible with 1.0.
    static let libSample = data("""
        7dxNaBNBFAfwt5NsKaTagEWURMhBxJbYhvoJgixqpEWxRXNYKbhEmpqladomKbW14IIUFEU8CHrszUu9BD2JGAvqUYpoS1FRe/CD
        iuBFjaLO7E7Mso1QEW//Hzwmb7Lz5iN7nTwqf/jRQKQQV8djNY9rjGiSgqKL1vN4y8MwEnE9QctptXNVBpPdhlFInSpUH/PWm5cP
        1rty5q7rJ8udGsZIdtTM9hpmtm+wRr2XcrDuyhn9mdhnh13nUOfhg/H9nQnP/jztlOK0ioyKVTxiPNbJfh9zntByQ8lCui1jnsgn
        B4YyqdbeMf6ZaBuRFZR1xbitMo/xPCLPT9TSNadeWnPyAI9uzx68a/kbITnPnsWd7Uv3t++4/fjJzOm52HQ7Oeuw67KQHfa+7Alf
        my28Cbrq8HeJdslaYu2+zV2qGN02ks+J3Ys4OpYvpAZa91bOQNgk63RrzjvQLHNdnvcGmVviXFawSU21jpR8xlPxaFj2uVsm3zFN
        /qSvWO3X2WfvSeFz/56UEQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwH8S4RGVIbivVy+77KwYzgV2I5nNj6ZytFZ0+mhe
        db6utGJco1K91x8hzzip/KKhxIuGXdM28T4+Sqkn5heFRIU0Va/y8xk0K8Lsq+YrUflLAfJevtcuPRz+9j0cZycjzxrvhr6W1S8X
        F7ZMRd9fPV6su9czfOPMdFEffPCur+Sfm53tZ126+nPi5sT45MKdCx3no9f/9ftx61Zx5vmVY2ebAx/Nz2ta+i9v3J0MfcoEzi2G
        9h3oeSPW/As=
        """)

    /// An arm64 object file.
    static let helloObject = data("""
        O//r7T8eBgZGBgYIwQrEJ0AMBQYwkARiC0YGnCABSr9gROWzQzEzlB8fX5JaUYLQFx8f4hoRgmmeApJ5TEDagwlqBgtDA7K6+Pjk
        4pKizLx0HObBzJGB0hxMqPagcUHm5ecWJCaXxJfmlWfmpcTH+7ggyzugmasBdVcCEzTw0Iw0AmIJaJgyMElDMBDoAbEAEGcAVXNA
        NYHUFQAZbED6ApDWANLcQBwANYsFimHxgyc6cIK/1ftX/mVmmAhkTgBiED2FgaEh6G/1wRUHmOOveaTm5OQrpBXl5yokKrhkFpRU
        JmcoFCfmFuSkYosfFnTzBSBu0+WBuM+HA0LbQtMVGzsTB0iKQR6I+ZA8AEojfEyIcJVE4wuD+MyI8OcFYn4k/Yzo4RFfUFpSzJAT
        D0wdDPG5iZl5DDkluQVGYNIQTBqAlAEA
        """)

    /// X86_64 only, for macOS 10.13.
    static let helloIntel = data("""
        7ZrPaxNBFMff5kcbq61RRFpbYShWqkIT8VIQoZEEUy22tRVKQcdNM+0u7CZhd6MNeOhFwUOgCPoXKPgneBT00JsePPgPKIr4D3gw
        zuxMm9lJ0qLHMh94mX07O995My8TQl4+/v71px/AiANAjNpxapAEeAKIXcEItSI1jBdyNwqrhTvz0IEBB8N0vhhMZ7mwstxlfFoZ
        IPykZBDGEZDNoP2YqreQ5HqnJD9CArZkF2M/qJf8nnplodcn+TIpodcX0cMWcWrE66LnCL0zkh/bN741P/DsykaP+J4KvTHJl4kp
        y8e4XnlkV8rYrqxXu+i9Enorkh87IK/TYV7zueVcNH+RvCptXDIel2Niv+GWqg6uBV5PvZTkx6XufuV9iHHZDEzZj+qlFL2Uogcd
        +7ZRDaC3XlrRSyt6fUou2udqbvb2rUJ+djcHSNk3JPSM9lmR1zkOsJUVz7G5U7QdlvoR4lJZ2mZFDKzfQvxM7SAex1F2ViA6R0zk
        Z7/8v0Xd921IhH6MWqbuexnHLmXKDacs+kdFHO6HEeP+zavN528WP+/8fL1zbnfpgwN04lG4qHw0TNL1Dnc512yeaaEZxj05H76T
        9+amttTwA+JOXZ+icdglPu680H8g9u+C8C0E/8Xd4rOvxea1S/Tye4K+XH53731r4uUA65trnn1BL3JLrQnWblvs5o9vrVarSByn
        ita9qotMlLdrQWPNQr7p1hwC0fMttzGxDzPAjYg9mVFiiof7Y9B1Gf/yka3RaDQajUajOYQ8TuovgxqNRqPRaDQajUaj0Rx2TozD
        YtjOsOIcL16X7EqZeLDopbfBoz24Vg982OYDDAwnWcuLg59YlQ67FiabZK0eEGwRk4094pp2BQYhfIBxhdpQf7vuGv7XwOCVPeaf
        Dv12/X6M39/7aWJc8XdrxwnhI8BdwsBhGDz+jvVhHN6qefZDMyBC5y8=
        """)

    /// X86-64 Linux, dynamic, against glibc 2.28.
    static let elfDynamic = data("""
        rVZdbNtUFL62kzTdGITRwrQhZgFFoBFvi7qq2gaau44lzEDZWnhYO89NvCbCsSPHGek0RKXwF6mBilf2ABIPRdpDH3mj03gDpCFA
        GogHhKgEk0B9GFWlaTX3xuem1xd3HRJXsj+fn+/++Zxz75vHtOdEQUC0iehZRKSFnjagI9SQ7Lhg3SDagt8Pol6UwHKM8cMosLhP
        DPQUaTcS8Cqgxyiw+DD4URQYjKFQY03oMhgpotS6MU7WBXq6PorXwJ0iyyNrnIkH8kxf4E+xDqPPbAnzxE14I8CjSPfl5JJXiP2H
        8ejiR4D3sxTIGAUWnwY/inR7Xsa8BLqrJrBCDJ5Z+H+z8N8oyuAnc+PttUqTA/17rULaKtm1ero+OJAe6FeqjpJp+6RgoOMvjnX2
        8W4ntz1C/8AGetKz2OYJaMf6b0O1naVuYnuU6VcC3Mn1IMETNc/2Jug6Xm1er3qG6+llo2SjSs2rIqIkKx5Ax7Xc0FE9o2SUAzT+
        ngioCW7Dl0HfxY2VNS3Lkc+5Tlk25OFSxZvOF+WqUa5YJhJ2SYeehL3/Hi9wmBDuR2gcQw/GixgdjPNEpvO+cBIJ9ZSw656u5JwQ
        6EkOvof5e9oTSHXysh8/l1LAVe9NvSMe3ZZ4CROxSMYdxc8ctp9m7c83umYTrfj7sQ8kUQt8SYzM4OeLVLDujq8a2Nm2/89c89sz
        2eav2cZvyyOjWiv+NtmF1rbH2vAM8fd7V/Cqbn49lm0uYdWPf/n+728R7uLEVaJTX1VfUcfU0VMjWqvv1g3f11rpmxheeGrJ25Nt
        fpdrrqhNP3fltpRr3BZyjR/QcNPXmivZ5k+q3/N4rvFlMud/U7uRxR+n1XF1Qj2j6kHXE1e5+foHLuC5+H0X8fu+3UfwF5GLxPTH
        L77v03+8A/ARrtze8n2HTb5erv8uwDnI8yTXXzcnPwQ4D/4iZ6fxfB3irYcbh9aKBcjzrRwfyhYah/5pWVQA/14L1iODndaFwyAv
        w3pXof81kBHYfW4/Nmq0XvLtfG+gzzplc9I1X5fzlmFPyedNt1pybDmTUfYrg0gr2a+Z7kG546Vpw9SGlJLtmW4FKbbjmYo6lEt7
        xhRSCtN2dbqMlCm7pkB3IUF3A7FoVIsI3oTjYb1rWgYR4KtiefjLKRiegRSzqJ9zjbKpFwvuuoQUz6xjr7YrZhrlUh7373jtF/Rg
        Wq6jV4xCoWTjCeadctm0sb5axIN6xiT6H5oAD40j5hwPnd+RhwjEJ1vTmHMkdH4g7hxBTDxvZfg0LhdAkWXySYjIj90QU5RP425V
        DMc7X+dF5jxdY/g0TilB5sbn538IPysMn+aFLIX3T/r3NazdjkHOiVweHebGl7j9o3gCbCKXt+NSOG83+n+noC+Rq0NzUnRd4fd/
        AvhDXF2aj+Bvj+BPwZwyIC8Cf1G6c/xRdLj4Ze5NofvSRvH3BsdPxqAOg+OnnD///95l7piheynwP+H8U5zc4vhnob6djUfnD8//
        ELgSVzfp/ZO/nya5fj5i7kjs/eVaInq9vPwxx6fnzvVE9Px5/mego/xV4K/S8bvvHL+fg24fp6f8g5vEzxVmbLZl4MD8apP8+Qc=
        """)

    /// AArch64 Linux, static with musl, stripped.
    static let elfStatic = data("""
        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
        xD7mTyhctZa175Jr8P/Dn8nf/wU=
        """)

    /// An x86-64 shared library named libsample.so.1.
    static let elfLibrary = data("""
        rVRPb9MwFH92s67QbovGDoWhKcCNg8l2GgOxIWDaoYcxgTihkjamyWiSKQm048JtGjc+AId9DI4IvgYSp0n7AnBBYrjdc2OblT/S
        nuT84uf387N/z/abB411SghIK8EdKHoAa4iupfqWoSK+NahCWfQtJc7Ej0THCvoJ8sbZF6oj2AVvQh2f1bEKOqq8wVqPkHd0VccD
        DK9P6Tz6jzyJcn9bh7lv/Uc+qfkm8vaRZ+Ic6Cg1fCh4ZTg7G6xnFiZ/05Uo7dJo3WtD7H19X6KoGTEnzLxop8ubXpz1eArdsHXi
        YFnCFgfx86Vbc8h7JLR3jX2S11tA+jaZr01W3omgy4DNxrXdnbb36L2p8roIQM7jjbeHH66Ln6efYRp9M4gLRr1+HB8nah1GWlJ9
        /3XECcQAx88b8377eTKfS/U6bdLT9d5IIt5Kec9pd72447ziaRYmsbO0xBbZMjTC+AVPV5xRVKNxX44B83fjbDcC1olfssDLAsDv
        wJ+nwHjQfJ56EW8GvtIDlvN+PozyorANLOXdNGnueL4fxh1g7SSKeCwCskDMknutMztX1ULW4gfRVc41UeojdT8n2ndRK0mT+kp0
        QL9PFSP/BawdNeohsW7wLQMvDt/Igi/rL3HhlP2qdgV9kj/ufoORV9oNg39AdbxtxJv7v6m8hdr7aZzzcflXkVsC412j+rtmGflt
        ec7RJ/n71xDR0a/9Wb8n6HMNv+SvjNFf4jMlt2qf0Ln9l/r9Ag==
        """)

    /// A RISC-V object file.
    static let elfObject = data("""
        rVTNbtNAEJ7NTymlhLQ9ULWAjOgBIXWVWIgfiUMS0dJDxAHRGyhs7E1i4Y0texPSciAgcUTixokLJ16DN+AhkLiCeICytncbd2Mr
        HBh59pv9vLMz+zP7Zq+9X0AIlCD4A7PeTL4XEywLbcRWAy7CBWiuLf24K8iNchk+CfbnVMyx9+VFE72bHlDX9Yxe4DGDGA8dnx9Z
        AyMkzHcpVFW84yeAJghtrxZgU/Q3JX8lalqVaustevqtVYGS5LeEllJ5LUvc1vhViRtCL6X4A4/RbkBfGZZLhn1jTIPQ8YaGaeI6
        vgfNvhgSOKE1BvQ8mrFaDsZ3bjumX+8w0691SGT1TN/s2FFjRdyxY4VBbDA2cuuRQQjzEsMNQiu2LJKALUCtT8h9oQVYLChe3+8T
        nT9/+vesVHL4tZgtnvZVHpfjtjg3fituS3BV45P+fD5G3C5lrqGYebMiPm/8cg5fzOFLc9wNoeupuGq9N4VWsybBnE444IC6RJme
        TTjBIQ/quA7Y8hijw4iP7gkmnAdOd8RpCJgOOr2AMCrdZ13XHbMOsW1x2fqAhx6n+NHjw92QE+sl4PCIcdIVOBAxEitBGEQVhC3A
        7ZoBOxOB4g/s2LOPEWcI/oiH8H8ESdVPpKHtnxL97p6TddjQ+K+q/iSuyDjqhFXdr0ve1Pyf5cRHGl6Xdk0b90vitQX+t5Iq8Ofq
        SQ4Y5PgreSA5fV8mEvW89Bu+n7N/E3R2n1bkGen7dxjl3z7xBEzT/h9R/nmnxcp8Nf7dP8x5z5T/FM3e50pG/q8zXyFRq5L8sCD+
        +xz/z5LcXeD/Fw==
        """)

    /// An x64 console program, kernel32 only.
    static let windowsConsole = data("""
        842qYGBkYGBgYUAFDgyEQQUQ88nv4mPYwnlWcQejz1nFkIzMYoWCovz0osRcheTEvLz8EoWkVIWi0jyFzDwFF/9ghdz8lFQ9FQaG
        AFcGhpQ2Fga9F3cbYeZ9YFBi4GbiY2BgAnLYoIICUAx0EiOMz4SQhtEMAQhPMDMkgMxkhOtHZggg3C+A7F8FBgYNtADgweZpAwYG
        GQbiQQfQXAU88nolqRUlQNodyW/okQHUn6BXlJJYksjA8AYqgBJGCCc76CWVZuakZKbIQN0KVseBRV0BxDweWGSD1HFhqmMYBcMa
        hHo0vzHw6M1RMdj59T8QiFYDE6HHcRcVcKL16BW9zc/A4NPr+8ej86DjDlmg2H/RBKASw5P/RT2A9ASP5iMGsYfPjIKhCTxSc3Ly
        FdKK8nMVEhVcMgtKKpMzFIoTcwtyUnlBxcF/KIClF3R+BlLhdkkBUt5hAyug4tug9DEF0uQZGFwrMksCivKTU4uLQeVlaklwSYpH
        Yl5KTipINrwosyTVLRPI8XYN8nP1MTbSS8nJAVYCXMymXMysQYwBo3kdZx0ErYMFRoNi5AFgpLsD8QOF0aAYiQAA
        """)

    /// The same with a version resource and a manifest asking for administrator rights.
    static let windowsAdmin = data("""
        7VfNbxtFFH/ruFVjQppLJJCKmK5y4EBspylSqWw3EXbqCLex4jRIlRDZ7I7tlfbDzKwjW1xAlRAcIvUP6IFjj0ggVJA4IBAIiUqI
        ExIH+AMqwYVbRfjNeP1Rx6XhwKHCz5p5M2/e/N7Xenb22s0OGUSUpEdpjZ5MHbT5F7+Yp09n75+/Z1Tun99pupK1RNgQls9sKwjC
        iO1zJtoBcwNW3KoxP3R4eomoWiJy3j9Fn/z4a6qP9weZ9ExiniiByVwsXIgbXDL6c6yfjpf7nPaGQczQ3ntgxmD/6GBh6P/CaLyM
        6CU1qBLdTfYSMDcp6CzROTo5fQBc9g/r6Yh3IvCrI7GNFwP799LCsSKL6EEs0Hqnj9VsLb3fdj3Hdc7Fvmq9MxP0Wj28uX6xlV5q
        gp6QwqY4J9XY5txxPZrSU0k3yrceZMuH3lL28z+PQIvv4CEsf1dc0g9t+XDxl7NElcNrD8sffrV+7wXIjhb3oLLy/dFiGfx2+dY3
        2Te//mFKTyeVueeFrC5Cn1ms6Lairt1k0vJbHn9WHQdHMfWfl/F5c+Rw+4n1zrtJdDeWfxbzb9m/WycqddyoKkKbS6nOSx7VIqds
        BY7H1eobwo34hovJ66Xt66XK6oW043l4CaRmXknNnNo2qtP/+uOo/w5emKbi/0co+lW039g0FVNK6DMAj8K7z4FfAn903dCX6upj
        5M0J8tnkMeFAfhujjwB2JzFyl6wRWcZwfidxEf0u1egt9CXaxmiTtug65pvoNzBW9GXy978UbgItiS+ABBlPjPahoXbUKCJBLgXU
        AJpLHnEgB1SnEDo/a50sXUR7VfN9fa1eQ6YMeg06PrXIgn4X3liY6dcRFYHUAnKXbOSFwYqlNRW6en/dpOexv2+vqKW29kPtcoEb
        aJx17B3HkiNYDFxAu4FeSXvX/jMj2LtoAnuGmCuUpgtoq2gquwU6C/2qxnGoDSvRiWNR9DIyPr5/3GrPJm6UOm9bOtKGzroFnL6v
        wcBqE72HX0jLkDmQKt00pB29vkbzwKlg3NAIqhIteNjDbVKkn9M2quVBYsNrR9fK0jgqJlXXXczFhKoTLemPsB2d1QBxeOCjdZlN
        fqy/0nJXOr7HDriQbhjkzZV01mQ8sEPHDRp588bOxvIlk8kI9xTLCwOeN7tcmlcKqZwlJff3vS7D/kDmzbYILku7yX1LLvuuLUIZ
        1qNlO/QvW9JPH6yYzLcCt85ltDtqrJBiLBeJtow2g3p4QrBVs5CT3G7jztQt5AR/uw1Y7lSFe4AbVINLhQrcwUqpA+0IRiv8gHvM
        U33eVMuu4OuO7waujIQVhcJkbXfdVpe0vFm3PMnNjHYxM8lKLjP0IjMIAsnJ9LNTSE0P5f+U/gY=
        """)

    /// An ARM64 console program.
    static let windowsArm64 = data("""
        842qYGBkYGBgYUAFDgyEQQUQ88nv4mPYwnlWcQejz1nFkIzMYoWCovz0osRcheTEvLz8EoWkVIWi0jyFzDwFF/9ghdz8lFQ9FQaG
        AFcGhpRVLAxCvOpVMPM+MCgxcDPxMTAwATlsUEEBKAY6iRHGZ0JIw2iGAIQnmBkSGoEUI1w/MkMA4X4BZP8qMDBooAUABzZPGzAw
        yDAQDzqA5irgkdcrSa0oAdI+SH5Djwyg/gS9opTEkkQGhgdQAZQwQjjZQS+pNDMnJTNFBupWsDoOLOoKIOZxwCIbpI4LUx3DKBjW
        4B+//A9gGtjgwNggxOHp8JOB0f4aiA/MPBsUGRgmcvg6/HxszDBxEXND0BNm+VUw+QfM8locrhD1/9gdfxxgjr82GppDD3ik5uTk
        K6QV5ecqJCq4ZBaUVCZnKBQn5hbkpPKCioP/UABTj87PQCrcLilAyjtsYAVUfBuUPqZAmjwDg2tFZklAUX5yanExkOeeWhJckuKR
        mJeSkwqSDS/KLEl1ywRyvF2D/Fx9jI30UnJyRuOXGACrgwVGg2LkAWCk+zIsGA2HEQoA
        """)

    /// A 32-bit x86 program for the windows (GUI) subsystem.
    static let windowsX86 = data("""
        842qYGBkYGBgYUAFDgyEQQUQ88nv4mPYwnlWcQejz1nFkIzMYoWCovz0osRcheTEvLz8EoWkVIWi0jyFzDwFF/9ghdz8lFQ9FQaG
        AFcGBh9GFob/uxZcgpn3gIGJkZuRj4GBCchhgwoKQDHMVSA2E0IaRjMEIDzBxODQCKQYIfoE4PoFkNxuoMDAoIHPc1CrGAwYGGQY
        iAcZCqj2oAO9ktSKEiCtD3MQE2bgA41I0CtKSSxJZGBYDxVACROEEx30kkozc1IyU2SgbgWr48Cirig1Jz8Z6jYHqDouDHVODKNg
        RIHQzqdhAVlf/4vmKDgwGH7r9f0RFpglm8EA5AX8Fy0AUmH/RTOAVPMRlrjYw2dGwfACHqk5OfkKaUX5uQqJCi6ZBSWVyRkKxYm5
        BTmpvKDi4T8QMCDREQqItLNIAVLeYa0bgOJtQDxNATufgcG1IrMkoCg/ObW4GMhzTy0JLknxSMxLyUkFyYYXZZakumUCOd6uQX6u
        PsZGeik5OaP5lRYAVgcLjAbFyAPQ5hGngbiBnIGqwWiAjCwAAA==
        """)

    /// The x64 one signed by sign-pe-sample.py, by a made-up CA.
    static let windowsSigned = data("""
        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
        D42M1+9fYl2vuYbhXf5TsUqMmPK6WNPmTUy07sBbM8DOsNrZI0jCgqLiFT99K2eHtKlqCS/fr8zFCIAqXVXssuJ02wvdRIt9DH4y
        Qj+AzUaTrwRsDDyaktrIBg/lDlWbWfP6hS3kCAP9GrnR+yeGYLPNzotg1bCxoWnPjsODu6ptx48ouJ6oI7LBUaR6hpGeB2/6U2r0
        99vTnLaHNFCF35Ihiibi53ZXWGl2SYgoKcCVwQyQVs6uYohqGGhqhYzrSfsG9/1THdKBlKWDfXKe0seIUpo/i7JOHbUkGc4DDIYN
        AroTynk67zdnVOlb5S7Yhk+47WvzJv3aJFUCMx56+RaFokINPTt4HX+HwDt4XKGhUXrh0PFGh0SHqhPm4zmlexijDg8uKw/z3PKz
        Rg25y8QdFm++krorjU5s7upXDWZ5VEevfdl6bOh4TeDWe6CzcFOHn8T29qm7zT5NOwoV5MTUxyeayu6TWo5uDwtquptlzSZ7oN/d
        yPGJfWUcUfL3M6HqrxgVGiGZHgeTpOOwQTf3Rr43UeOWq61UTz/QFbI75OfL9cl5rzdEXq16p6jkcuwbbJqyArfmW8sA7G1eUbuo
        s5f57l/jc0vaSySbr13nmuDyJiWjCHVXiZiwtVe23652lK8S0RO8B/0T
        """)

    /// A DLL exporting sample_answer and sample_twice.
    static let windowsDLL = data("""
        842qYGBkYGBgYUAFDgyEQQUQ88nv4mPYwnlWcQejz1nFkIzMYoWCovz0osRcheTEvLz8EoWkVIWi0jyFzDwFF/9ghdz8lFQ9FQaG
        AFcGhpQ2Fob+rpp7MPM+MCgpcDPxMTAwATlsUEEBKGZgaGCE8ZkQ0jCaIQDhCSaGBEaYJhiFyYcwFRQYGJKweQ4YACrYxA0YGGQY
        qAf0SlIrSoC0PJLf0CMD6MQEvaKUxJJEBoY5UAGUMEI42UEvqTQzJyUzRQbqVrA6DizqCiDmqcAiG6SOC1MdwygY1iDUo/PpDlDG
        ij0MZmrBmb0snLGHz4yC4Q3+QwEsPaDzkYEHsNxhhBYVIBwM5EcDcTIQFyfmFuSk6qXk5DBwA4sxMSBOBwqXgooqoCaIdHxiXnF5
        ahGMV1KemZwKkmZhYmVhZgxAp0dzJ30ArA4WGA2KkQeAkQ7KsC0KDPCM26MAoeWBeIrCaBANZwAA
        """)

    /// The DLL's import library, made by lld.
    static let windowsImportLibrary = data("""
        rVTNTsJAEP5K22jQgwcPmmjExCPht/wciIGIiUQsDcK5NpQEkmIIkODNGw/AgbtvwtPwGrjdXaBri6aGSWazOzu7M998s3tbskad
        3n00GRMl5ZunBHu6oPHZWxTAESCtAHkOKDqgxrkuXDXN2ovRaLbM6uPrQ7NmtBpNc2wNhk4Xpqm363X/Pj6ZA9tuPbX1Z7NaaVXI
        gf5gyE+b1vt42h1BXAkek2m/04WwCI20uEOqEqgrCZjLgK4AcWJYqBQ+JESgQKUq4z+Yg7DtRyOCZ1v7qsbMCdtxkr9izmsMazZf
        2GK2ZxG48sVoppLo29bEusvwJc6J2kQ/+JqUB2Wkltwvv/E7IbqAKGXElgiQU6IRfhcbZZyRUaGzHSK6rfBDEj3kTc+19OBNhF3K
        Ldom3NYnt7O4cuNJiRWiKFgMMh6ywaNhuUpnvFxJNC2DA/dwlfVyVfJxkArkwF/aawp3D6bwueczvj6b+HPfUnLM+0zMvbz8Sabr
        5wT4/Y3vioyHekVaLub5I9drkvvMjXTJ4wY9ZNrRoeuoacGRLsRI3v+DBvoG
        """)

    /// A static library of one MSVC object.
    static let windowsStaticLibrary = data("""
        lVTNaxNBFH/7kXQbPUSRUkToCjmlOtmEtrQSpEiVCopBq3gp7WZ3GlMmSdldkx5FiiDiQf8D/wCvIgoiFDx79u7Fmyc9WedzP0Xr
        LI958+bH+82b99s533YD78HlSsPODqfgO5n4YkvtblcAwKD2TdkaITfd/hBCd7BH8JY7DCc4UKto0vcwwH/zLSR8miRipBr/jsMo
        VmjU3W38lXFpQVA1neVFxeg/seDCys/dAx1gBsRAEd6PIBlz1DY0yAwbnG3ku5GbDUOYw62C8xF1wxD+MR4x3H424eyf860iP8Be
        NMYqNk/tWQ4HlSogH3cf9mp3VKhD7U0x3xW0l+WtUSvT+6jrYj0teRvN5cK5D/RcwKrC3fWnX98yns1D7tZj97k5vXmomXrJNLRO
        frYbV+93bt3euJTpdT7Ke27SjN+prbFCQTulyJegzf3PtJcaWNTT74md9dEAdwM8sT3iDnv2GAdhfzS0Wy3URKKqEzIHm5kSLDmz
        7ldTBRpgxh7DlLl3Mo5VY+9MvDsbx87Fnh3vpvXGrs3Q5pTyrpF3omFprekck7500YS0zowCxhCYlMZMjlFn+3D2xg9TciX6KnHM
        vLqbL+/rJYlJtMWr0DoS8/rxyxdlgUnpaopjalJNn9rXX03FJzutpFM4syU0uoPdCDkO84+OWCXqVRA3Zsv6Tdm9JGLLHooI2ukT
        9dP8onl6mk8I8jLyvQiQe2sQIePBluv7VDG97MtT+Q0=
        """)

    /// An MSVC x64 object file.
    static let windowsObject = data("""
        S2njYNCx/JHVwsTAIMYAAXolqRUlDAggD8QhjAwoQIHBIEEvJbEkEVWYoRhNnQODwQG9pOJiBgKgAaSuAtVACezmOeilFKUml5Sl
        wsS0gbgbTR0DlwCDXkpqUmm6SjBMKACIt2Ga56RXgGqvChCzAcNDiwnC54Taq29ogeHuFiY0AQ4BhlCPzqc7QPbEHgYzteDMXhbO
        2MOMLEysLMyMAei0gr5rRIB/UIhVcWJuQU5qfGJecXlqEbpoSXlmcioL0MSPQOwC8igDoyDMcjMGGzD7AjAuGRk4gCymMIiMR35u
        alJRarlCck5iXrpCWWpRcWZ+noKRkZ6hHsRX3FAzQDQoJXBAaVDsCyB5kJmBBc4CqWEDs3jgYgJwlghcVgIuJgNnKcBlkdMbKNiY
        GeVhKc8tZxckwpDTGhNYDXKgQyIBOZ0xY6hhhqhBSmMsYDUwt+2T8vnOArULkb5YwWq0YWFza7cWK1QNIm2BfcEYAFWztmnSRDaI
        GqR0xQ5WowJNTcdsPBeyw10mBEs6GG7mgKTRtNTEEj0DAxD7/3+QT1xycnwTM/OgIaYA9T8LNPYQIgrQOISI6KVl5sAyzT+gOemM
        KTk5eskoyVcXlOeQ0x+DXk5OWW58YkoKMMWkMyCnQgYA
        """)

    /// An MS-DOS program: a 32-byte header and a few instructions.
    static let dosProgram = data("""
        843yYmBkYGBgAuL//wUYwBwgkIFQDHzyu/gYtnCeVdzB4HNW0SM1JydfIa0oP1chUcEls6CkMjlDoTgxtyAnVQUA
        """)

}
