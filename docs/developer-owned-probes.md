# Owned developer probes

Owned probes are developer-only diagnostics. They do not select normal app data.
Place your own fixture executables at these fixed paths in the source checkout
before compiling the app.

- `.developer-fixtures/owned-probes/TNF Test Source.app/Contents/MacOS/source`
  has bundle identifier `local.tnf.productionfixture0`.
- `.developer-fixtures/owned-probes/TNFWebKitFixture.app/Contents/MacOS/TNFWebKitFixture`
  has bundle identifier `local.tnf.webkitfixture0`.

The compiled source location determines this directory, not the current working
directory. Recompile after moving the checkout. There is no environment or CLI
path override. An absent, non-executable, non-regular or symlinked fixture refuses
owned-probe parsing. The supplied executable path must exactly match the selected
fixture. Bundle, PID, launch-time, parent-process and HAL continuity checks still
apply. A bundle probe does not fall back to a main process.

Normal app startup does not inspect these fixtures. Do not commit fixture apps,
recordings, session data or diagnostic output. Historical local recipes are not
portable commands for this placement and remain historical records.

## Native test qualification

Default `swift test` skips tests that instantiate an audio engine or host native
windows. `TNF_RUN_NATIVE_TESTS=1 swift test` opts into those preserved tests only
when a developer deliberately prepares a native qualification environment.
Offline rendering still starts an engine and is included in this opt-in.
Node construction and pure serialization tests remain in default CI.
Real capture additionally requires the existing `RUN_INTEGRATION_TESTS=1` opt-in.
Fake capture tests that do not need an engine stay in default CI.
