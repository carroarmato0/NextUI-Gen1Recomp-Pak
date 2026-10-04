The upstream watcher failed **outside** the contract checks, so it says nothing yet about whether upstream broke anything. No branch, draft or checklist was updated, and the pak stays on whatever `upstream.lock` on main pins.

Failed run: @RUN@

This is our own pipeline: a download, a pinned hash, a packaging or `gh` step. The one seen so far was a pin against a URL whose content moves (the CA bundle, 2026-09-25 to 2026-10-04). Find the failed step in the run, fix it on main, then re-run the workflow with **Run workflow**.

This issue is rolling: a later failure updates it, and the next run that gets through the checks closes it.
