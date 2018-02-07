mvc-socket
===

[![Build Status](https://travis-ci.org/tonyday567/mvc-socket.svg)](https://travis-ci.org/tonyday567/mvc-socket) [![Hackage](https://img.shields.io/hackage/v/mvc-socket.svg)](https://hackage.haskell.org/package/mvc-socket) [![lts](https://www.stackage.org/package/mvc-socket/badge/lts)](http://stackage.org/lts/package/mvc-socket) [![nightly](https://www.stackage.org/package/mvc-socket/badge/nightly)](http://stackage.org/nightly/package/mvc-socket) 

results
---

```include
other/results.md
```

recipe
---

```
stack build --test --exec "$(stack path --local-install-root)/bin/mvc-socket-example" --exec "$(stack path --local-bin)/pandoc -f markdown -i other/header.md app/example.md other/footer.md -t html -o index.html --filter pandoc-include --mathjax" --exec "$(stack path --local-bin)/pandoc -f markdown -i app/example.md -t markdown -o readme.md --filter pandoc-include --mathjax" --file-watch
```

reference
---

- [ghc options](https://downloads.haskell.org/~ghc/latest/docs/html/users_guide/flags.html#flag-reference)
- [pragmas](https://downloads.haskell.org/~ghc/latest/docs/html/users_guide/lang.html)
- [libraries](https://www.stackage.org/)
- [protolude](https://www.stackage.org/package/protolude)
- [optparse-generic](https://www.stackage.org/package/optparse-generic)
- [hoogle](https://www.stackage.org/package/hoogle)
- [doctest](https://www.stackage.org/package/doctest)
