# Third-party notices

Codealong for iPhone is under the Apache License 2.0 ([LICENSE](LICENSE), [NOTICE](NOTICE)). It
includes the work of others, under their own licenses, listed here. Its Rust core is built with
crates that cargo fetches as it builds (`core/Cargo.lock` lists them), each under its own license;
none of them is kept in this repository.

## Tabler Icons

The sessions' emblem icons in `Codealong/Assets.xcassets/Emblems/`, from
[Tabler Icons](https://tabler.io/icons) 3.44.0. `scripts/build-emblems.sh` draws them from the
outline paths in the Mac app's `src/ui/icons.ts`, at the commit `core/Cargo.toml` pins.

```text
MIT License

Copyright (c) 2020-2026 Paweł Kuna

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
