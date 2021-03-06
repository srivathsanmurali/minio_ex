defmodule Minio.Signer do
  alias Minio.Helper

  @sign_v4_algo "AWS4-HMAC-SHA256"
  @unsigned_payload "UNSIGNED-PAYLOAD"

  defp get_signed_headers(headers) do
    headers
    |> Map.keys()
    |> Enum.map(&String.downcase/1)
    |> Enum.sort()
    |> Enum.join(";")
  end

  defp get_scope(client, request_datetime) do
    [
      Helper.iso8601_date(request_datetime),
      client.region,
      "s3",
      "aws4_request"
    ]
    |> Enum.join("/")
  end

  defp credential(client, request_datetime) do
    client.access_key <> "/" <> get_scope(client, request_datetime)
  end

  defp get_query(client, headers, request_datetime, expires) do
    %{
      "X-Amz-Algorithm" => @sign_v4_algo,
      "X-Amz-Credential" => credential(client, request_datetime),
      "X-Amz-Date" => Helper.iso8601_datetime(request_datetime),
      "X-Amz-Expires" => to_string(expires),
      "X-Amz-SignedHeaders" => get_signed_headers(headers)
    }
    |> URI.encode_query()
  end

  defp get_canonical_rquest(method, uri, headers) do
    [
      method |> Atom.to_string() |> String.upcase(),
      uri.path,
      uri.query
    ]
    |> Kernel.++(
      Enum.sort(headers)
      |> Enum.map(fn {k, v} ->
        "#{String.downcase(k)}:#{to_string(v) |> String.trim()}"
      end)
    )
    |> Kernel.++(["", get_signed_headers(headers), @unsigned_payload])
    |> Enum.join("\n")
  end

  defp signing_key(client, request_datetime) do
    "AWS4#{client.secret_key}"
    |> Helper.hmac(Helper.iso8601_date(request_datetime))
    |> Helper.hmac(client.region)
    |> Helper.hmac("s3")
    |> Helper.hmac("aws4_request")
  end

  defp string_to_sign(client, canonical_request, request_datetime) do
    [
      @sign_v4_algo,
      Helper.iso8601_datetime(request_datetime),
      get_scope(client, request_datetime),
      canonical_request
      |> Helper.sha256()
      |> Helper.hex_digest()
    ]
    |> Enum.join("\n")
  end

  def presigned_url(
        %Minio{} = client,
        method,
        opts
      ) do
    with :ok <- Helper.is_valid_bucket_name(opts[:bucket_name]),
         :ok <- Helper.is_valid_object_name(opts[:object_name]) do

      request_datetime = Keyword.get(opts, :request_datetime, DateTime.utc_now())
      link_expiry = Keyword.get(opts, :link_expiry, 604_800)
      
      uri = Helper.get_target_uri(client.endpoint, opts)
      headers_to_sign = %{"Host" => Helper.remove_default_port(uri)}
      query = get_query(
        client,
        headers_to_sign,
        request_datetime,
        link_expiry
      )
      new_uri = Map.put(uri, :query, query)

      string_to_sign =
        string_to_sign(
          client,
          get_canonical_rquest(method, new_uri, headers_to_sign),
          request_datetime
        )

      signature =
        signing_key(client, request_datetime)
        |> Helper.hmac(string_to_sign)
        |> Helper.hex_digest()

      {:ok, "#{URI.to_string(new_uri)}&X-Amz-Signature=#{signature}"}
    else
      err -> err
    end
  end
end
