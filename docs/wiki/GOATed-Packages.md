# Install GOATed packages

A `.goated` package distributes declarative prompts, skills and related content. It does not install a native executable extension.

1. Obtain a package whose source and contents you can review. The repository’s [Vue Toolkit example](../../examples/vue-toolkit/README.md) is a small starting point.
2. Open **Settings → GOATed → Extensions → User** and import the local package.
3. Inspect its content and requested contributions. Choose Global scope or the intended Pen.
4. Install it disabled if you want to finish reviewing before use, or deliberately enable it.
5. Verify that its prompts/skills appear in the selected scope. Use the installed row to disable, export or remove it later.

Optional MCP suggestions open a separate configuration flow; importing the package does not start those servers. Skills remain instructions, not authority to run commands or change permissions.

Invalid paths, unsupported content and oversized archives are rejected. Do not extract or run a rejected package to bypass those checks. Authors can use the [package-format reference](../reference/PACKAGES.md) and [extension API](../EXTENSIONS.md).
