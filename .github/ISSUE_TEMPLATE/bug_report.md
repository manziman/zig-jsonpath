name: Bug Report
description: File a bug report
labels: ["bug"]
body:
  - type: markdown
    attributes:
      value: |
        A bug is when something works differently than it is expected to.
        ## Remember to search before filing a new report
        Please search for this bug in the issue tracker, and use a bug report title that
        would have made your bug report turn up in the search results for your search query.
  - type: input
    id: version
    attributes:
      label: Zig Version
      description: "The output of `zig version`"
      placeholder: "0.10.0-dev.4583+875e98a57"
    validations:
      required: true
  - type: textarea
    id: repro
    attributes:
      label: Steps to Reproduce and Observed Behavior
      description: What exactly can someone else do, in order to observe the problem that you observed? Include the output and all error messages.
    validations:
      required: true
  - type: textarea
    id: expected
    attributes:
      label: Expected Behavior
      description: What did you expect to happen instead?
    validations:
      required: true