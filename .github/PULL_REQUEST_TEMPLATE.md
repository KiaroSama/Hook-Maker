<!--
  Hook Maker is proprietary (All Rights Reserved). External pull requests are
  accepted only by prior written agreement with the copyright holder.
-->

## Summary

Describe what this change does and why.

## Related issue

Closes #

## Type of change

- [ ] Bug fix
- [ ] New hook
- [ ] New feature
- [ ] Refactor / maintenance
- [ ] Documentation

## Checklist

- [ ] I have the right to submit this change and agree to the project's LICENSE terms.
- [ ] No secrets, tokens, local project paths, or `.env` values are included (only `.env.example`).
- [ ] Code comments and docs are in English and match the existing style.
- [ ] A new/changed hook stays silent when its trigger condition is not met (no unconditional noise).
- [ ] `.\scripts\Validate-Config.ps1` passes.
- [ ] `.\scripts\Test-Engine.ps1` passes (both `pwsh` and Windows PowerShell if the change touches the engine).
