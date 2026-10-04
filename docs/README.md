## 📁 Docs

Discover the repository code and files with the functions exported from this module.

### 💻 Functions

- Read-File (path, startLine, endLine): Returns file contents with line numbers, with support for large files in chunks.
- List-Directory (path, depth, glob, respectGitignore): Shows a tree view that skips folders like node_modules, bin/obj and .git.
- Find-Files (glob pattern): Finds files quickly by name or pattern, e.g., \*_/_.cs.
- Search-Code (regex, path, fileGlob, contextLines): Works like ripgrep, returning file, line number and surrounding lines.
