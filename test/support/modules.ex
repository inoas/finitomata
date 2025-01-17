defmodule Finitomata.Test.P1 do
  @moduledoc false

  @fsm """
  [*] --> s1 : to_s1
  s1 --> s2 : to_s2
  s1 --> s3 : to_s3
  s2 --> [*] : ok
  s3 --> [*] : ok
  """

  use Finitomata, {@fsm, Finitomata.PlantUML}

  @impl Finitomata
  def on_transition(:s1, :to_s2, event_payload, state_payload) do
    Logger.info(
      "[✓ ⇄] with: " <>
        inspect(
          event_payload: event_payload,
          state: state_payload
        )
    )

    {:ok, :s2, state_payload}
  end
end

defmodule Finitomata.Test.P2 do
  @moduledoc false

  @fsm """
  s1 --> |to_s2| s2
  s1 --> |to_s3| s3
  """

  use Finitomata, fsm: @fsm, syntax: Finitomata.Mermaid, impl_for: :all
end
