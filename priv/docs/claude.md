# Connect Claude

Add Hamaca to Claude and you can ask about your boards in plain words: "what's going on with
relay?" or "anything need me?". Claude answers from your boards, names the board, and links
every card it mentions.

You connect once. Claude then sees every board you're a member of, including boards you join
later.

## The address

Hamaca's MCP server is at:

```
https://hamaca.app/mcp
```

If you host your own Hamaca, use your server's main address with `/mcp` on the end, such as
`https://boards.example.com/mcp`. Use the main address, not another name that points at the
same server, or sign-in won't match.

## claude.ai, Claude Desktop and the Claude mobile app

1. In claude.ai, open **Settings → Connectors** and click **Add custom connector**.
2. Name it **Hamaca** and paste the address above.
3. Click **Connect**. Hamaca asks you to sign in if you aren't already, then shows what Claude
   will be able to do. Click **Allow**.

The custom connector then works in Claude Desktop and the Claude mobile app too.

## Claude Code

Run this once, using your own address if you self-host:

```bash
claude mcp add --transport http hamaca https://hamaca.app/mcp
```

Then type `/mcp` in Claude Code, pick **hamaca** and sign in. Your browser opens Hamaca's
**Allow** screen.

## What Claude can do

Claude acts as you, and only on boards you're a member of. It can:

- list your boards, and how many cards wait on you on each one;
- sum up a board: what's waiting on you, what agents are working on, and what shipped this week;
- list everything waiting on you across your boards, oldest first;
- show one card: its stage, status, who has the baton, a spec excerpt and recent activity.

For now Claude can only read. It can't create cards, comment, approve, reject, answer
questions or move cards. You still do those on the board or in the Hamaca app.

## Disconnecting

You can remove the connector in Claude at any time. A way to revoke a connection from inside
Hamaca is coming in a later release.
