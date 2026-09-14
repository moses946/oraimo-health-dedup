# Static analysis of the Oraimo Health app

Reading the official app's code is the complement to capturing its traffic.
Captures tell you *what* it sent; the code can tell you *why*, and often names
the UUIDs and constants outright.

This is interoperability research on a device you own. Keep it that way: the
goal is to understand the protocol, not to redistribute anyone's code.

## Getting the APK

The APK is not in this repository and must not be committed — it is someone
else's copyrighted binary, and it is large. `research/apk/` is gitignored.

Pull it from a phone that has the app installed:

```bash
adb shell pm list packages | grep -i oraimo     # find the package name
adb shell pm path <package.name>                # usually several paths
adb pull /data/app/.../base.apk research/apk/oraimo-base.apk
```

`pm path` typically returns a `base.apk` plus several `split_config.*.apk`
files. The splits are per-density resources and per-ABI native libraries; the
protocol code lives in `base.apk`.

If you only need the code and want a smaller file to move around:

```bash
mkdir -p research/apk/code && cd research/apk/code
unzip -o ../oraimo-base.apk 'classes*.dex' 'AndroidManifest.xml' 'lib/arm64-v8a/*'
```

`classes*.dex` is the Java/Kotlin code. `lib/arm64-v8a/*` matters only if the
packet building turns out to be in native code, which does happen with
white-label wearable SDKs.

## Tools

`jadx` is the usual choice, but its GitHub release downloads are blocked by
this environment's egress policy. Two alternatives that are reachable:

```bash
pip install androguard        # decompiles and searches DEX from Python
```

```bash
# baksmali, from Maven Central, for smali disassembly
curl -sSLO https://repo1.maven.org/maven2/org/smali/baksmali/<version>/baksmali-<version>-fat.jar
java -jar baksmali-*-fat.jar d classes.dex -o smali/
```

The Android SDK's own `apkanalyzer` (installed at
`$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/apkanalyzer`) is useful for a quick
look at the manifest, permissions and DEX class list without decompiling.

## What to look for

Work from the concrete towards the speculative:

1. **UUID string constants.** Search the decompiled output for the
   `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` pattern, and for four-hex-digit
   short forms near `BluetoothGatt` calls. Any UUID found here is a
   *candidate* until a capture confirms the app actually uses it.
2. **`BluetoothGattCallback` subclasses.** `onCharacteristicChanged`,
   `onCharacteristicWrite` and `writeCharacteristic` call sites are where the
   protocol meets the transport.
3. **Whoever builds the byte arrays.** Look for classes that assemble
   `byte[]` with a fixed first byte, a length field and a trailing checksum —
   that shape is what framing looks like in source.
4. **Checksum routines.** CRC tables, XOR folds, or a sum-and-mask.
5. **Watch-face handling.** File extensions, magic numbers, any use of
   `Deflater`/`GZIPOutputStream`, and anything that chunks a byte array into
   fixed-size pieces.
6. **Vendor SDK packages.** These watches are frequently built on a
   white-label chipset SDK. If you find one, its name is worth searching for:
   the same SDK often has public documentation or prior reverse-engineering
   work behind it.
7. **Obfuscation.** If class and method names are single letters, the app was
   run through R8. String constants usually survive, so the UUID search still
   works even when nothing else is readable.

## Recording what you find

Anything found in the APK goes into the Protocol Database as an **observation**
with its source noted — `"UUID xxxx appears in class Foo.bar()"` — and stays at
low confidence until a capture shows the watch actually responding to it.

Code can lie about runtime behaviour: dead code, unused constants, and
branches for other watch models all look identical to the real thing in a
decompiler. **A UUID in the APK is a hypothesis. A UUID in a capture is
evidence.**
