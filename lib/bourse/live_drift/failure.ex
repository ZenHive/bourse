defmodule Bourse.LiveDrift.Failure do
  @moduledoc "Sanitized failure contract persisted by the live drift lane."

  @type t :: %{
          required(:actual_type) => String.t(),
          required(:expected_type) => String.t(),
          required(:field) => String.t(),
          required(:method) => atom() | String.t(),
          required(:recapture) => String.t(),
          required(:reauthor) => String.t(),
          required(:venue) => String.t()
        }

  @doc "Builds one failure without retaining provider bodies, requests, or credentials."
  @spec new(String.t(), atom() | String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) :: t()
  def new(venue, method, field, expected_type, actual_type, recapture, reauthor) do
    %{
      actual_type: actual_type,
      expected_type: expected_type,
      field: field,
      method: method,
      recapture: recapture,
      reauthor: reauthor,
      venue: venue
    }
  end
end
