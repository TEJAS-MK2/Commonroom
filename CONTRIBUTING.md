# Contributing to Commonroom

Thank you for considering a contribution. Commonroom is a small, community-focused project, and thoughtful improvements are welcome.

## Ways to contribute

- Report reproducible bugs or visual issues.
- Suggest focused product improvements.
- Improve accessibility, responsive behavior, and documentation.
- Fix defects or improve performance.
- Add tests and strengthen the deployment checks.

For security vulnerabilities, do not open a public issue. Follow [SECURITY.md](SECURITY.md).

## Before you start

1. Check existing issues and pull requests to avoid duplicating work.
2. For a significant change, open an issue first to discuss the approach.
3. Keep changes focused. Avoid unrelated refactors in a bug-fix pull request.
4. Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Local development

1. Fork the repository and clone your fork.
2. Configure your own Supabase project in `supabase/config.js` using a browser-safe publishable key.
3. Apply and review `supabase/schema.sql` in your development Supabase project.
4. Start a local static server:

   ```bash
   python -m http.server 8000
   ```

5. Open http://localhost:8000.

Do not commit credentials, database passwords, service-role keys, private user data, or local environment files.

## Branch and commit guidelines

- Create a short, descriptive branch from the default branch.
- Use clear commit messages, for example:
  - `Fix mobile sidebar dismissal`
  - `Improve message loading state`
  - `Document local Supabase setup`
- Prefer small commits that are easy to review.

## Quality checklist

Before submitting a pull request:

- [ ] Run `node --input-type=module --check < app.js`.
- [ ] Confirm the app loads without console errors.
- [ ] Test desktop and mobile layouts, including narrow screens.
- [ ] Test the affected interaction and at least one nearby workflow.
- [ ] Check keyboard navigation, visible focus, and reduced-motion behavior where relevant.
- [ ] Escape user-controlled content before inserting it into HTML.
- [ ] Do not introduce privileged credentials or expose private data.
- [ ] Update documentation when behavior, configuration, or setup changes.
- [ ] Include screenshots or a short recording for visible UI changes.

## Pull requests

A useful pull request includes:

1. A concise summary of the problem and solution.
2. The reason for the change and any relevant context.
3. Steps used to test it, including browser/device sizes for UI work.
4. Screenshots for before/after visual changes.
5. Any schema, configuration, or deployment implications.

Keep pull requests focused and be prepared to make revisions after review. Maintainers may request changes, ask for clarification, or decline changes that do not fit the project's goals or safety requirements.

## Style guidance

- Prefer readable vanilla JavaScript and small, focused functions.
- Keep the interface responsive and usable with touch, keyboard, and pointer input.
- Respect `prefers-reduced-motion`.
- Use semantic HTML and accessible labels.
- Keep dependencies small and pin externally loaded versions.
- Treat all chat content and display names as untrusted input.
- Never assume a client-side sender key represents a verified person.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
