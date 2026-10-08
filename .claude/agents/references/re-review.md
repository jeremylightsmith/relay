# Re-reviewing after a fix pass

Read this when you have established that this is a re-review — a fix commit sits on top of the
work, or your prompt carries a findings block. It is the shared conduct only — the trigger, what
still blocks, and your own Pass/Approve line live in your own definition.

A re-review is not a fresh review: check only that your findings were addressed and that the fix
regressed nothing.

**Do not re-run your checklist.** A fresh full read always turns up something you did not
mention the first time, and every one of those costs another fix pass, gate run and review.

Never re-raise a finding the fixer rebutted with technical reasoning unless you can refute that
reasoning on the code.

Say in your verdict that this was a re-review, and which findings you were checking.
