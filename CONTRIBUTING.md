# Contributing to TypeSpec

Thank you for considering contributing to TypeSpec! This document provides guidelines and information about contributing to this project.

## How to Contribute

### 1. Fork the Repository

```bash
git clone https://github.com/yourusername/typespec.git
cd typespec
git checkout -b feature/amazing-feature
```

### 2. Make Your Changes

- Follow the existing code style
- Add tests for new features
- Update documentation as needed
- Keep commits atomic and well-described

### 3. Commit Your Changes

```bash
git commit -m 'Add amazing feature'
```

### 4. Push to Your Branch

```bash
git push origin feature/amazing-feature
```

### 5. Open a Pull Request

Go to the repository and create a Pull Request.

## Development Guidelines

### Code Style

- Use consistent indentation (2 spaces)
- Keep lines under 100 characters
- Use meaningful variable and function names

### Documentation

- Update README.md for user-facing changes
- Update CHANGELOG.md following [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format
- Add or update FAQ entries in the relevant spec file ([type.md](type.md#7-faq) or [schema.md](schema.md#15-faq))
- If changing syntax, update the grammar in [`grammar.ebnf`](grammar.ebnf) and the corresponding section in [schema.md §13](schema.md#13-ebnf-grammar)

### Testing

- Add test cases for new features
- Ensure all existing tests pass
- Test edge cases and error conditions

## Reporting Issues

When reporting issues, please include:

1. **Description** - Clear description of the problem
2. **Steps to reproduce** - How to reproduce the issue
3. **Expected behavior** - What you expected to happen
4. **Actual behavior** - What actually happened
5. **Environment** - OS, database, TypeSpec version

## Feature Requests

We welcome feature requests! Please:

1. Check if the feature already exists
2. Describe the use case
3. Explain why it would be valuable
4. Consider implementation details

## License

By contributing to TypeSpec, you agree that your contributions will be licensed under the [MIT License](LICENSE).
