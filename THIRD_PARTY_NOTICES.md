# Third-Party Notices

AudioRouterNow bundles the following open-source components. Their licenses are reproduced below as required by their respective terms.

---

## Python 3.14

- **License:** Python Software Foundation License (PSF-2.0)
- **Source:** https://www.python.org
- **Copyright:** Copyright © 2001–2026 Python Software Foundation

The Python runtime is embedded in the application bundle via PyInstaller.
Full license text: https://docs.python.org/3/license.html

---

## rumps 0.4.0

- **License:** BSD 2-Clause License
- **Source:** https://github.com/jaredks/rumps
- **Copyright:** Copyright © 2020 Jared Suttles

```
Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

---

## PyObjC 12.2 (pyobjc-core, pyobjc-framework-Cocoa)

- **License:** MIT License
- **Source:** https://github.com/ronaldoussoren/pyobjc
- **Copyright:** Copyright © 2002–2024 Ronald Oussoren and contributors

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## PyInstaller 6.20.0

- **License:** GPL-2.0-or-later with Bootloader Exception
- **Source:** https://pyinstaller.org
- **Copyright:** Copyright © 2010–2024 PyInstaller Development Team

PyInstaller is used to build the application bundle. Its GPL license includes
a special exception that explicitly permits the resulting bundled executable
to be distributed under any license (including GPL-3.0 as used here).

> **Bootloader Exception:** Distributing programs bundled with PyInstaller's
> bootloader does not make those programs subject to GPL. You may distribute
> such programs under terms of your choice.

Full license: https://github.com/pyinstaller/pyinstaller/blob/develop/COPYING.txt

---

## altgraph 0.17.5 and macholib 1.16.4

- **License:** MIT License
- **Source:** https://altgraph.readthedocs.io / https://github.com/ronaldoussoren/macholib
- **Copyright:** Copyright © 2004 Istvan Albert and Bob Ippolito; macholib © Ronald Oussoren

These libraries are used by PyInstaller during the build process and are
bundled as indirect dependencies. License text identical to PyObjC above (MIT).

---

## OpenSSL 3.x (libssl.3.dylib, libcrypto.3.dylib)

- **License:** Apache License 2.0
- **Source:** https://openssl.org
- **Copyright:** Copyright © 1998–2024 The OpenSSL Project Authors

These libraries are bundled as indirect dependencies of the Python stdlib
(`ssl` module). AudioRouterNow does **not** make any network connections using
OpenSSL — it is present solely because the Python runtime links against it.

Full license: https://github.com/openssl/openssl/blob/master/LICENSE.txt

---

## XZ Utils / liblzma 5.x (liblzma.5.dylib)

- **License:** Public Domain / MIT / LGPL-2.1-or-later (depending on component)
- **Source:** https://tukaani.org/xz/
- **Copyright:** Lasse Collin and contributors

Bundled as an indirect dependency of the Python stdlib (`lzma` module).
Full license: https://github.com/tukaani-project/xz/blob/master/COPYING

---

## Zstandard / libzstd 1.x (libzstd.1.dylib)

- **License:** BSD 3-Clause License or GPL-2.0
- **Source:** https://github.com/facebook/zstd
- **Copyright:** Copyright © Meta Platforms, Inc. and affiliates

Bundled as an indirect Python stdlib dependency.
Full license: https://github.com/facebook/zstd/blob/dev/LICENSE

---

## mpdecimal / libmpdec 4.x (libmpdec.4.dylib)

- **License:** BSD 2-Clause License
- **Source:** https://www.bytereef.org/mpdecimal/
- **Copyright:** Copyright © 2008–2024 Stefan Krah

Bundled as an indirect dependency of the Python stdlib (`decimal` module).
Full license: https://www.bytereef.org/mpdecimal/license.html

---

## ds_store 1.3.1

- **License:** BSD 3-Clause License
- **Source:** https://github.com/al45tair/ds_store
- **Copyright:** Copyright © 2014 Alastair Houghton

Bundled as an indirect dependency of PyInstaller (used during `.app` bundle creation).
Full license: https://github.com/al45tair/ds_store/blob/master/LICENSE

---

## mac_alias 2.2.0

- **License:** MIT License
- **Source:** https://github.com/al45tair/mac_alias
- **Copyright:** Copyright © 2014 Alastair Houghton

Bundled as an indirect dependency of PyInstaller. License text identical to PyObjC above (MIT).

---

## Apple Frameworks

AudioRouterNow links against the following Apple system frameworks which are
part of macOS and are governed by the macOS Software License Agreement:

- CoreAudio / AudioServerPlugin API (HAL driver)
- AppKit / Foundation (menu bar UI)
- CoreFoundation

These frameworks are not redistributed — they are loaded from the operating
system at runtime.
