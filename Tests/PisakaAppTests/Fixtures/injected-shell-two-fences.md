# Lint

Check that the linter is there:

```sh
command -v swiftlint >/dev/null 2>&1 || exit 1
echo "swiftlint is not installed"
```

Then run it:

```sh
swiftlint lint --strict
```
