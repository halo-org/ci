# Gives each item a store: the URI of the first builder in $builders that
# builds the item's system, or "" if none does. $builders is a list in the Nix
# machines format.
(
  $builders | split("\n")
  | map(sub("#.*"; "") | [splits("\\s+") | select(. != "")] | select(. != []))
) as $builders
| map(
    .system as $system
    | .store = ([$builders[] | select(.[1] // "" | split(",") | any(. == $system)) | .[0]] | first // "")
  )
