# One context = one Linux user + one Orca server + one coordinator harness.
{
  personal = {
    primary = "claude"; # Opus 5.5 / Fable 5.1
    orcaPort = 6768;
  };
  work = {
    primary = "claude"; # Opus 5.5 / Fable 5.1
    orcaPort = 6769;
  };
}
