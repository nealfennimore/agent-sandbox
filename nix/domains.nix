# Domain allowlists. "*" = all HTTP methods; a list restricts to those
# methods. A key without a port covers ports 80 and 443. To reach another
# port, add the port to the key: "internal.example.com:8443" = "*";
{
  # Bare minimum domains to get Claude (and Anthropic-backed OpenCode)
  # working.
  baseDomains = {
    "anthropic.com" = "*";
    "claude.com" = "*";
  };

  # Bare minimum domains to get Codex working. "openai.com" also covers
  # api.openai.com and auth.openai.com (suffix match); chatgpt.com is
  # used by ChatGPT-plan auth and its backend API.
  codexBaseDomains = {
    "openai.com" = "*";
    "chatgpt.com" = "*";
  };

  # Domains the agent is allowed to reach by default (read-only access
  # to GitHub here).
  agentDomains = {
    "raw.githubusercontent.com" = [
      "GET"
      "HEAD"
    ];
    "api.github.com" = [
      "GET"
      "HEAD"
    ];
    "github.com" = [
      "GET"
      "HEAD"
    ];
  };
}
