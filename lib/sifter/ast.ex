defmodule Sifter.AST do
  @moduledoc """
  Semantic AST for filters. Both the string and JSON front-ends should build these nodes.
  """

  @type op ::
          :eq
          | :neq
          | :gt
          | :gte
          | :lt
          | :lte
          | :in
          | :nin
          | :contains_all
          | :starts_with
          | :ends_with
  @type field_path :: [String.t()]

  @type t ::
          Sifter.AST.And.t()
          | Sifter.AST.Or.t()
          | Sifter.AST.Not.t()
          | Sifter.AST.Cmp.t()
          | Sifter.AST.FullText.t()

  defmodule And do
    @enforce_keys [:children]
    defstruct children: []

    @type t :: %__MODULE__{children: [Sifter.AST.t()]}
  end

  defmodule Or do
    @enforce_keys [:children]
    defstruct children: []

    @type t :: %__MODULE__{children: [Sifter.AST.t()]}
  end

  defmodule Not do
    @enforce_keys [:expr]
    defstruct expr: nil

    @type t :: %__MODULE__{expr: Sifter.AST.t()}
  end

  defmodule Cmp do
    @enforce_keys [:field_path, :op, :value]
    defstruct field_path: [], op: nil, value: nil

    @type t :: %__MODULE__{
            field_path: Sifter.AST.field_path(),
            op: Sifter.AST.op(),
            value: term() | [term()]
          }
  end

  defmodule FullText do
    @enforce_keys [:term]
    defstruct term: ""

    @type t :: %__MODULE__{term: String.t()}
  end
end
