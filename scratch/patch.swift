        var deduplicated = [NSRange]()
        var lastAdded: NSRange?

        for r in result where r != lastAdded {
            deduplicated.append(r)
            lastAdded = r
        }

        return deduplicated
    }
}
