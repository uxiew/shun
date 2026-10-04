<p align="center">
  <img src="packages/flterm/screenshots/banner.png" alt="Ghostty's full VT engine, as a Flutter widget" width="100%">
</p>

<p align="center">
  <a href="https://pub.dev/packages/libghostty"><img alt="libghostty" src="https://img.shields.io/pub/v/libghostty?label=libghostty"></a>
  <a href="https://pub.dev/packages/flterm"><img alt="flterm" src="https://img.shields.io/pub/v/flterm?label=flterm"></a>
  <a href="https://github.com/elias8/libghostty/actions"><img alt="ci" src="https://github.com/elias8/libghostty/actions/workflows/build.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="https://github.com/sponsors/elias8"><img alt="sponsor" src="https://img.shields.io/github/sponsors/elias8?logo=githubsponsors&label=sponsor"></a>
</p>

[Ghostty](https://ghostty.org)'s libghostty-vt engine for Dart, with
a Flutter widget on top.

## [`libghostty`](packages/libghostty)

Dart bindings to libghostty-vt for VT parsing, key/mouse encoding,
OSC/SGR parsing, and screen formatting. FFI on native, WASM on web.

```dart
import 'package:libghostty/libghostty.dart';

final terminal = Terminal(cols: 80, rows: 24)
  ..onWritePty = (data) => pty.write(data)
  ..onTitleChanged = () => print('title: ${terminal.title}');

terminal.write(ptyOutput);
```

## [`flterm`](packages/flterm)

Flutter widget that renders a libghostty `Terminal` with adaptive
input, themes, selection, and scrollback.

```dart
import 'package:flterm/flterm.dart';

final controller = TerminalController()
  ..onOutput = (bytes) => pty.write(bytes)
  ..onResize = (size) => pty.resize(size.cols, size.rows);

ptyOutputStream.listen(controller.write);

TerminalView(controller: controller);
```

## License

MIT. See [LICENSE](LICENSE).
