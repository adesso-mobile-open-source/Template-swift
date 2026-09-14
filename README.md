# template-swift
Template Repositories for Swift Libraries

## How To Use
Use this Repo as template via GH Templating function

## Copyright Headers
Every Swift source file must carry the adesso SE Apache-2.0 copyright header.
Use the helper script to add it automatically:

```sh
# Add the header to any .swift file that is missing it
scripts/add-copyright-header.sh

# Limit the scan to specific files or directories
scripts/add-copyright-header.sh Sources Tests

# Check-only mode: report files missing the header and exit non-zero (CI-friendly)
scripts/add-copyright-header.sh --check
```

Files that already contain the header are left untouched.
