import app/ctx
import app/ext
import app/handle/helper
import app/instance
import app/struct/server
import ed25519/public_key
import ed25519/signature
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict
import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import sql
import wisp
import youid/uuid

pub fn sign(query: helper.Query, ctx: ctx.Context) {
  let query = dict.from_list(query)
  use challenge <- helper.require_query(query, "challenge")
  use challenge <- helper.try_res(
    uuid.from_string(challenge)
    |> result.replace_error(helper.construct_error("challenge is not uuid", 400)),
  )

  let public_key =
    ctx.private_key
    |> public_key.derive_key()

  let sig =
    signature.create(
      ctx.private_key,
      public_key,
      challenge |> uuid.to_bit_array(),
    )

  server.encode_signing_response(server.SigningResponse(public_key, sig))
  |> json.to_string_tree()
  |> wisp.json_response(200)
}

pub fn identity_key(json: dynamic.Dynamic, ctx: ctx.Context) {
  use body <- helper.guard_json(json, server.identify_instance_body_decoder())
  use requester_key <- helper.try_res(
    ext.ping_sign(body.host)
    |> result.map_error(fn(err) {
      helper.construct_error(err |> string.inspect, 400)
    }),
  )
  let req_key_bits = requester_key |> public_key.serialize_to_bits

  use found_domain <- helper.guard_db(sql.get_domain(ctx.conn, req_key_bits))
  let res = case list.first(found_domain.rows) {
    Ok(row) ->
      case row.domain {
        option.Some(domain) -> {
          use domain <- result.try(
            instance.new(domain)
            |> result.replace_error(helper.construct_error(
              "Domain isn't valid",
              409,
            )),
          )
          use <- bool.guard(
            body.host != domain,
            Error(helper.construct_error(
              // Maybe change this
              "Key does not match domain",
              409,
            )),
          )
          Ok(Nil)
        }
        option.None ->
          Error(helper.construct_error("key marked as compromised", 400))
      }
    Error(Nil) -> {
      // Register this
      instance.identify(ctx.conn, req_key_bits, body.host)
      |> result.replace_error(helper.construct_error("database error", 500))
      |> result.replace(Nil)
    }
  }
  use Nil <- helper.try_res(res)

  let my_pubkey = public_key.derive_key(ctx.private_key)
  use <- bool.guard(
    my_pubkey != body.public_key,
    helper.construct_error("Not my key", 400),
  )

  let sig =
    signature.create(
      ctx.private_key,
      my_pubkey,
      body.challenge |> uuid.to_bit_array(),
    )
  let key = crypto.strong_random_bytes(48) |> bit_array.base64_url_encode(False)
  // TODO: Register identity key

  server.encode_identify_instance_response(server.IdentifyInstanceResponse(
    identity_key: key,
    signature: sig,
    public_key: my_pubkey,
  ))
  |> json.to_string_tree()
  |> wisp.json_response(200)
}
