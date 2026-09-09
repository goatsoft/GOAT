# Guide active work with Lead

Lead lets you add direction to an active chat without starting a separate conversation.

1. While the model is working, type a short instruction in the composer, such as “Keep the existing layout and change only the introduction.”
2. Click **Lead**, or press Return. The instruction is saved in the same chat.
3. Allow the current response and its current tool action to finish. GOAT applies the queued instruction before starting another tool action.
4. If an approval is pending, approve or deny it normally. Lead does not dismiss the dialog or approve the action.

Use **Stop** when you intend to interrupt. Stopping does not undo completed work. A queued instruction remains in the chat even if you stop before it is applied.

Lead accepts text. Send attachments after the active turn finishes. Expand **Using tools** or **Used tools** to inspect the current action and previous results; Lead messages and final replies remain outside that group.

See [Tools and permissions](../overview/TOOLS.md) for how actions are authorised.
