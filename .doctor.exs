%Doctor.Config{
  ignore_modules: [
    # Generator-only module — creates 110 exchange modules at compile time.
    # Doctor sees the `for` loop body's function defs as belonging to this module.
    Bourse.Exchanges,
    # Generator macro module — Doctor sees quoted `def unquote(fn_name)` raw
    # endpoint wrappers as Bourse.Exchange functions and cannot explain them.
    Bourse.Exchange,
    # Facade with generated unified methods (@doc false) + defdelegate default-arg
    # arities that Doctor can't trace specs for. Real docs on Bourse.Exchange.
    Bourse
  ]
}
