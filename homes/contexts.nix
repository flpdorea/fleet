# One context = one Linux user + one Orca server + one firstmate fleet.
# Each context's firstmate config lives in homes/<context>/config/.
{
  personal = {
    primary = "pi"; # GPT-5.6 through the ChatGPT subscription
    orcaPort = 6768;
  };
  work = {
    primary = "claude"; # Opus 5.5 / Fable 5.1
    orcaPort = 6769;
  };
}
