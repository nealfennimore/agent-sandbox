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

  # Bare minimum domains to get Antigravity CLI (`agy`) working.
  # "googleapis.com" covers the suffix hosts the client uses:
  # cloudcode-pa (the agent backend), oauth2 (token refresh), www
  # (userinfo) and generativelanguage (GEMINI_API_KEY requests).
  # accounts.google.com is the Google sign-in host, and
  # antigravity.google serves the product endpoints, for example the
  # sign-in redirect and the version check.
  antigravityBaseDomains = {
    "googleapis.com" = "*";
    "accounts.google.com" = "*";
    "antigravity.google" = "*";
    # Profile images for the signed-in account. Images are reads only.
    "lh3.googleusercontent.com" = [
      "GET"
      "HEAD"
    ];
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
