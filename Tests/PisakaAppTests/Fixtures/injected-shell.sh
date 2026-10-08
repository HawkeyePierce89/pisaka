command -v swiftlint >/dev/null 2>&1 || exit 1
echo "swiftlint is not installed"
swiftlint lint --strict
