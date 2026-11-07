# NitPick's FFmpeg

NitPick uses FFmpeg under the GNU Lesser General Public License, version 2.1 (LGPL). This repository holds the exact FFmpeg source we build and the script we build it with.

## The source

NitPick ships FFmpeg 9.0.2 unmodified:

- Source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
- SHA-256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`

`Vendor/ffmpeg/VERSION` pins the version and checksum, and the build script refuses any tarball that doesn't match.

## The build

`Vendor/ffmpeg/build-ffmpeg.sh` is the script NitPick is built with. It builds FFmpeg as four shared libraries (libavformat, libavcodec, libavutil, libswresample) for Apple Silicon Macs on macOS 15 or later, without FFmpeg's GPL, non-free parts or any video decoder. Its comments say why each choice was made.

You need a Mac with Xcode's command line tools. Then:

```bash
Vendor/ffmpeg/build-ffmpeg.sh
```

The libraries are written to `Packages/NitPickKit/Binaries/` as `.xcframework` folders.

## Replacing FFmpeg inside NitPick

1. Change the source and build it with the script. Keep the same FFmpeg version, so NitPick can still call it.
2. Put your library files in `NitPick.app/Contents/Frameworks/`, in place of the original.
3. Re-sign the app on your Mac, so macOS lets the new libraries load:

   ```bash
   codesign --force --deep -s - NitPick.app
   ```

4. NitPick now runs on your FFmpeg.

A copy you re-sign runs only on your Mac, and isn't covered by the Mac App Store's updates. The in-app purchase also can't verify it to provide Pro features. If you wish to enjoy full features, please contact vbdevelop@protonmail.com with the screenshots that shows you purchased NitPick Pro on the App Store.

## License

FFmpeg is under the LGPL v2.1. `LICENSE` holds the full text.
