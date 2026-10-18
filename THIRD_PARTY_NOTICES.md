# Third-party notices

RingonomiTV's original Swift/tvOS implementation is licensed under MIT; see
[LICENSE](LICENSE). Third-party names identify compatibility or attribution.
They do not imply endorsement or affiliation.

## Komorebi

- Source: https://github.com/BeerEgg2001/Komorebi
- Copyright (c) 2026 BeerEgg2001
- License: MIT. The notice and full terms are retained in [LICENSE](LICENSE).
- RingonomiTV reimplements its television UI and client behavior for tvOS.

## KonomiTV

- Source: https://github.com/tsukumijima/KonomiTV
- Copyright (c) 2021-2026 tsukumi
- License: MIT. The full notice is in [KonomiTV-MIT.txt](App/Licenses/KonomiTV-MIT.txt).
- API field names, request/response contracts, and recording settings follow
  KonomiTV's API schemas. The server implementation is not bundled here.
- Keyword-search genre labels follow KonomiTV's
  [ProgramUtils.ts](https://github.com/tsukumijima/KonomiTV/blob/0a32188274b81c1e7bed642474b208bd2a543a6b/client/src/utils/ProgramUtils.ts).

## TVVLCKit / VLCKit

- Source: https://code.videolan.org/videolan/VLCKit/
- Official binary source: https://downloads.videolan.org/cocoapods/prod/
- License: GNU Lesser General Public License, version 2.1; see the upstream
  [COPYING notice](App/Licenses/TVVLCKit-COPYING.txt).
- The binary framework is downloaded locally by `bootstrap.sh` and is excluded
  from this Git repository. RingonomiTV does not modify the framework.
- The MIT license for RingonomiTV does not replace the terms of VLCKit, libVLC,
  or their included components. Before distributing a built application,
  review the exact bundled components, notices, corresponding source, and
  relinking obligations for that distribution. This repository currently
  distributes source, not signed application binaries.

## XcodeGen

- Source: https://github.com/yonaskolb/XcodeGen
- License: MIT. This development tool is downloaded separately and is not
  included in the application or this Git repository.

## libaribcaption

- Source: https://github.com/xqq/libaribcaption/tree/37dde0f32652c32aa98bf92278944d1cfb2e7354
- Archive: https://codeload.github.com/xqq/libaribcaption/tar.gz/37dde0f32652c32aa98bf92278944d1cfb2e7354
- Version: 1.1.2 at commit `37dde0f32652c32aa98bf92278944d1cfb2e7354`.
- License: MIT; the fixed-source notice is in
  [libaribcaption-MIT.txt](App/Licenses/libaribcaption-MIT.txt).
- The embedded MD5 implementation has its own upstream notice in
  [libaribcaption-MD5-notice.txt](App/Licenses/libaribcaption-MD5-notice.txt).
- `prepare-captions.sh` builds static tvOS device and simulator libraries with
  CoreText and assembles the local XCFramework. The generated framework and
  dependency sources remain outside Git.
