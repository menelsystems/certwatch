%% Extracts dNSName entries from a certificate's subjectAltName extension.
%% Accepts either a full DER certificate (x509_entry) or a bare
%% TBSCertificate (precert_entry). Returns [] on anything it can't decode.
-module(cert_ffi).
-export([domains/1]).

-include_lib("public_key/include/public_key.hrl").

domains(Der) ->
    try
        san_names(extensions(Der))
    catch
        _:_ -> []
    end.

%% Full certs decode via pkix_decode_cert, which pre-decodes known
%% extension values. Bare TBS (precerts) fall back to the plain PKIX
%% decode, whose extension values are still raw DER.
extensions(Der) ->
    try
        #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{extensions = Es}} =
            public_key:pkix_decode_cert(Der, otp),
        {decoded, Es}
    catch
        _:_ ->
            #'TBSCertificate'{extensions = RawEs} =
                public_key:der_decode('TBSCertificate', Der),
            {raw, RawEs}
    end.

san_names({decoded, Es}) when is_list(Es) ->
    lists:flatten([names(V)
                   || #'Extension'{extnID = Id, extnValue = V} <- Es,
                      Id =:= ?'id-ce-subjectAltName']);
san_names({raw, Es}) when is_list(Es) ->
    lists:flatten([names(public_key:der_decode('SubjectAltName',
                                               iolist_to_binary([V])))
                   || #'Extension'{extnID = Id, extnValue = V} <- Es,
                      Id =:= ?'id-ce-subjectAltName']);
san_names(_) ->
    [].

names(Names) when is_list(Names) ->
    [unicode:characters_to_binary(D) || {dNSName, D} <- Names];
names(_) ->
    [].
