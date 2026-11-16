defmodule Raxol.Payments.Ramp.Offer do
  @moduledoc "Validated snake_case ramp/1 offer. Nested contract objects use string keys."
  @derive {Jason.Encoder,
           only: [
             :contract_version,
             :kind,
             :offer_id,
             :capability_revision,
             :provider_id,
             :direction,
             :fiat,
             :crypto,
             :rail,
             :bounds,
             :interaction,
             :availability,
             :disclosures,
             :observed_at
           ]}
  defstruct [
    :contract_version,
    :kind,
    :offer_id,
    :capability_revision,
    :provider_id,
    :direction,
    :fiat,
    :crypto,
    :rail,
    :bounds,
    :interaction,
    :availability,
    :disclosures,
    :observed_at
  ]
end

defmodule Raxol.Payments.Ramp.Intent do
  @moduledoc "Validated snake_case ramp/1 intent. Nested contract objects use string keys."
  @derive {Jason.Encoder,
           only: [
             :contract_version,
             :kind,
             :direction,
             :exact,
             :fiat,
             :crypto,
             :recipient,
             :region,
             :route
           ]}
  defstruct [
    :contract_version,
    :kind,
    :direction,
    :exact,
    :fiat,
    :crypto,
    :recipient,
    :region,
    :route
  ]
end

defmodule Raxol.Payments.Ramp.Preview do
  @moduledoc "Validated snake_case ramp/1 preview. Nested contract objects use string keys."
  @derive {Jason.Encoder,
           only: [
             :contract_version,
             :kind,
             :operation_id,
             :quote_id,
             :offer_id,
             :capability_revision,
             :request_digest,
             :pay,
             :receive,
             :fees,
             :expires_at,
             :leg_order,
             :disclosures
           ]}
  defstruct [
    :contract_version,
    :kind,
    :operation_id,
    :quote_id,
    :offer_id,
    :capability_revision,
    :request_digest,
    :pay,
    :receive,
    :fees,
    :expires_at,
    :leg_order,
    :disclosures
  ]
end

defmodule Raxol.Payments.Ramp.Snapshot do
  @moduledoc "Validated snake_case ramp/1 snapshot. Nested contract objects use string keys."
  @derive {Jason.Encoder,
           only: [
             :contract_version,
             :kind,
             :operation_id,
             :revision,
             :direction,
             :leg_order,
             :peer,
             :xochi,
             :allowed_actions,
             :updated_at,
             :terminal
           ]}
  defstruct [
    :contract_version,
    :kind,
    :operation_id,
    :revision,
    :direction,
    :leg_order,
    :peer,
    :xochi,
    :allowed_actions,
    :updated_at,
    :terminal
  ]
end

defmodule Raxol.Payments.Ramp.Command do
  @moduledoc "Validated snake_case ramp/1 command. Nested contract objects use string keys."
  @derive {Jason.Encoder,
           only: [
             :contract_version,
             :kind,
             :operation_id,
             :leg,
             :action,
             :context,
             :quote_id,
             :accepted_disclosure_codes
           ]}
  defstruct [
    :contract_version,
    :kind,
    :operation_id,
    :leg,
    :action,
    :context,
    :quote_id,
    :accepted_disclosure_codes
  ]
end

defmodule Raxol.Payments.Ramp.Error do
  @moduledoc "Validated snake_case ramp/1 error. Nested contract objects use string keys."
  @derive {Jason.Encoder, only: [:contract_version, :kind, :code]}
  defstruct [:contract_version, :kind, :code]
end
