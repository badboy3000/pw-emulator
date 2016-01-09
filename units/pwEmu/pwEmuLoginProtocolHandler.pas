unit pwEmuLoginProtocolHandler;

interface

uses windows, winsock, swooshPacket, serverDecl, classes, System.Generics.Collections,
  math, HMAC, Hash, MD5, hmac_md5, pwEmuWorldManager, swooshOctetConverter;

type
  TpwAuthParams = packed record
    /// <remarks>
    /// Username saved class locally because it is needed for key generation.
    /// </remarks>
    username: AnsiString;
    /// <remarks>
    /// loginRequestHash is saved here (same as username) for key generation.
    /// </remarks>
    loginRequestHash: THashKey;
    // these two are generated randomly. cmKey is generated by server and sent to client. smKey vice versa.
    cmKey: THashKey;
    smKey: THashKey;

    accInfo: TpwAccountDetails;

  end;

Type
  TpwEmuLoginProtocolHandler = class


    // These two are actually the correct decryption keys.

    /// <remarks>
    /// c2s decryption key.
    /// </remarks>
    c2sKey: THashKey;
    /// <remarks>
    /// s2c decryption key.
    /// </remarks>
    s2CKey: THashKey;

    constructor Create ( config: TbigServerConfig; worldMan: TpwEmuWorldManager );

    // builder

    /// <remarks>
    /// This is only packet that is not sent as a response, it'S challenge. So we have no packet as argument.
    /// </remarks>
    Function build_s2c_01_ChallengePacket( connectionID: TSocket; BundleID: Cardinal ): TInternalSwooshPacket; // 1

    function build_s2c_02_KeyExchangePacket( packet: TInternalSwooshPacket ): TInternalSwooshPacket; // 3

    function build_s2c_05_Errorpacket ( packet: TInternalSwooshPacket; errorCode: integer; errorMessage: AnsiString ): TInternalSwooshPacket;

    function build_s2c_04_OnlineAnnounce ( packet: TInternalSwooshPacket ): TInternalSwooshPacket;

    // parser
    Function parse_c2s_03_UserLoginAnnouncePacket( packet: TInternalSwooshPacket ): integer; // 2
    function parse_c2s_02_KeyExchangePacket( packet: TInternalSwooshPacket ): Boolean;       // 4

    // helper functions
    Function GenerateC2S_Key( username: AnsiString; loginRequestHash, cmKey: THashKey ): THashKey;
    Function GenerateS2C_Key( username: AnsiString; loginRequestHash, smKey: THashKey ): THashKey;
    Function HashAnsiStringMD5( str: AnsiString ): THashKey;
    Function BuildHMACMD5( DataHash: THashKey; ChallengeKey: THashKey ): THashKey;

    /// <remarks>
    /// Removes all auth parameters for a connection ID. This avoids future connections having same ID and thus corrupting data.
    /// </remarks>
    procedure removeAuthparams ( cid: Cardinal );

  private
    _config: TbigServerConfig;

    /// <remarks>
    /// ChallengeKey - from initial Challenge packet.
    /// </remarks>
    ChallengeKey: THashKey;

    // just for converting the string hash to octets.
    _oc: TswooshOctetConverter;

    // this saves the shitload of seperate info each login request needs. On parse_c2s_02_KeyExchangePacket, the connection ID entry is removed from this.
    // Not needed anymore afterwards then.
    _authInfo: TDictionary< Cardinal, TpwAuthParams >;

    // for checking auth stuff.
    _worldMan: TpwEmuWorldManager;

  const
    // ONLY FOR FUCKING DEBUG!!!
    _debugUsername = 'swoosh';
    _debugpassword = 'fuckyou';
    function CompareHashKeys( HashKey1, HashKey2: THashKey ): Boolean;
  end;

implementation

constructor TpwEmuLoginProtocolHandler.Create ( config: TbigServerConfig; worldMan: TpwEmuWorldManager );
var
  i: integer;
begin
  Randomize;
  self._config := config;

  self._authInfo := TDictionary< Cardinal, TpwAuthParams >.Create;

  // self.dbInterface := TSwooshDBInterface.Create( self._config );

  // will create db in case it doesn't exist.
  // self.dbInterface.CreateTable( 'pwEmu', 'logins' );
  self._oc := TswooshOctetConverter.Create;
  self._worldMan := worldMan;

  copymemory(@self.ChallengeKey[ 0 ],@self._config.pwChallengeKey[ 0 ], 16 );

end;

procedure TpwEmuLoginProtocolHandler.removeAuthparams ( cid: Cardinal );
begin
  self._authInfo.Remove( cid );
end;

Function TpwEmuLoginProtocolHandler.build_s2c_01_ChallengePacket( connectionID: TSocket; BundleID: Cardinal ): TInternalSwooshPacket;
begin

  result := TInternalSwooshPacket.Create;
  result.connectionID := connectionID;
  result.BundleID := BundleID;
  result.Flush;
  result.WriteCUInt( 1 );
  result.WriteCUInt( 50 );                          // length following this byte
  result.WriteOctets(@self.ChallengeKey[ 0 ], 16 ); // already writes length!  ChallengeKey.
  result.WriteRawData( self._config.pwVersion, 4 );
  result.Writebyte( 0 );
  result.WriteOctets(@self._config.pwCrcHash[ 0 ], length( self._config.pwCrcHash )); // already writes length!
  result.Writebyte( 0 );

end;

function TpwEmuLoginProtocolHandler.build_s2c_05_Errorpacket ( packet: TInternalSwooshPacket; errorCode: integer; errorMessage: AnsiString )
    : TInternalSwooshPacket;
begin
  result := packet;
  result.Flush;
  result.Writebyte( 5 ); // opcode 0x05
  result.WriteCUInt( length( errorMessage ) + 2 );
  result.Writebyte( errorCode ); // error type  ; 2 = user not exist; 3 = client's wrong message; 4 = "timed out"
  result.WriteANSIString( errorMessage );
  self.removeAuthparams( packet.connectionID );
end;

function TpwEmuLoginProtocolHandler.build_s2c_04_OnlineAnnounce ( packet: TInternalSwooshPacket ): TInternalSwooshPacket;
var
  tempAuthParams: TpwAuthParams;
begin

  if ( self._authInfo.TryGetValue( packet.connectionID, tempAuthParams ))
  then
  begin
    result := packet;
    result.Flush;

    // See if the connection ID is saved in doct.

    result.WriteCUInt( 4 );
    result.WriteCUInt( 29 );
    result.WriteDWORD_BE( tempAuthParams.accInfo.accountID );
    result.WriteDWORD( 233 );
    result.Writebyte( 0 );
    result.WriteDWORD( 1 );
    result.WriteDWORD( 0 );
    result.WriteDWORD( $FFFFFFFF );
    result.WriteDWORD( 0 );
    result.WriteDWORD( 0 );
  end
  else
  begin
    result := self.build_s2c_05_Errorpacket( packet, 1, 'Error retiving account details.' );
  end;

  // remove the auth param shit now. Nobody needs it anymore.
  self.removeAuthparams( packet.connectionID );

end;

Function TpwEmuLoginProtocolHandler.parse_c2s_03_UserLoginAnnouncePacket( packet: TInternalSwooshPacket ): integer;
var
  dbAccountHash: THashKey;
  // hmac(accountHash,ChallengeKey)
  ownLoginRequestHash: THashKey; // "temp" on my overview paper
  debugHash          : THashKey;
  tempAuthParams     : TpwAuthParams;
  i                  : integer;
begin

  // Now, let's already generate cmKey for future keyexchange.
  // Also add the connection ID to dict, so future steps can use that info.
  for i := 0 to 15 do
    tempAuthParams.cmKey[ i ] := RandomRange( 10, 250 );

  packet.ReadCUInt;
  packet.ReadCUInt;
  tempAuthParams.username := packet.ReadAnsiString;
  packet.ReadCUInt;
  tempAuthParams.loginRequestHash := packet.ReadHashKey;

  // see step 3 in the schematic.
  // Check login info.

  tempAuthParams.accInfo := self._worldMan.getAccountInfo( tempAuthParams.username, 12345678 ); // Gets data for username.

  if ( tempAuthParams.accInfo.accountID > 0 )
  then
  begin

    dbAccountHash := self._oc.stringToHashkey( tempAuthParams.accInfo.loginHash );

    // account exists.
    ownLoginRequestHash := self.BuildHMACMD5( dbAccountHash, self.ChallengeKey );
    debugHash := self.HashAnsiStringMD5( self._debugUsername + self._debugpassword );

    if self.CompareHashKeys( ownLoginRequestHash, tempAuthParams.loginRequestHash ) // temp == loginrequesthash
    then
    begin
      // login correct
      // okay, so we can now calculate the c2s key.

      // Add some data to dict. This is for s2c key.
      self._authInfo.Add( packet.connectionID, tempAuthParams );

      // generate the data.
      self.GenerateC2S_Key( tempAuthParams.username, ownLoginRequestHash, tempAuthParams.cmKey );
      result := 0;

    end
    else
    begin
      result := 3; // Client's wrong password message
    end;

  end
  else
  begin
    // account doesn't even exist, faggot.
    result := 2; // user doesn't exist error code
  end;

end;

function TpwEmuLoginProtocolHandler.build_s2c_02_KeyExchangePacket( packet: TInternalSwooshPacket ): TInternalSwooshPacket;
var
  tempAuthParams: TpwAuthParams;
begin

  if ( self._authInfo.TryGetValue( packet.connectionID, tempAuthParams ))
  then
  begin

    result := packet;
    result.Flush;
    result.WriteCUInt( 2 );
    result.WriteCUInt( 18 );
    result.WriteOctets(@tempAuthParams.cmKey[ 0 ], 16 );
    result.Writebyte( 0 );
  end;

end;

function TpwEmuLoginProtocolHandler.parse_c2s_02_KeyExchangePacket( packet: TInternalSwooshPacket ): Boolean; // 4
var
  tempAuthParams: TpwAuthParams;
begin
  if ( self._authInfo.TryGetValue( packet.connectionID, tempAuthParams ))
  then
  begin

    packet.ReadCUInt;                           // Opcode
    packet.ReadCUInt;                           // PacketLength
    packet.ReadCUInt;                           // Keylength
    tempAuthParams.smKey := packet.ReadHashKey; // Key

    self.GenerateS2C_Key( tempAuthParams.username, tempAuthParams.loginRequestHash, tempAuthParams.smKey );

    result := True;
  end
  else
    result := False;

end;

// meins (1) - seins  (3) - wenn pwd richtig dann : meins (2) - seins  (2)

Function TpwEmuLoginProtocolHandler.GenerateC2S_Key( username: AnsiString; loginRequestHash, cmKey: THashKey ): THashKey; // 3
var
  TempConnotatedKey: array [ 0 .. 31 ] of Byte;
  ctx              : THMAC_Context;
  HmacMac          : TMD5Digest;
begin
  copymemory(@TempConnotatedKey[ 0 ],@loginRequestHash[ 0 ], 16 );
  copymemory(@TempConnotatedKey[ 16 ],@cmKey[ 0 ], 16 );

  hmac_MD5_init( ctx, @username[ 1 ], length( username ));
  hmac_MD5_update( ctx, @TempConnotatedKey[ 0 ], 32 );
  hmac_MD5_final( ctx, HmacMac );

  copymemory(@self.c2sKey[ 0 ],@HmacMac[ 0 ], 16 );

  result := self.c2sKey;
end;

Function TpwEmuLoginProtocolHandler.GenerateS2C_Key( username: AnsiString; loginRequestHash, smKey: THashKey ): THashKey; // 4
var
  TempConnotatedKey: array [ 0 .. 31 ] of Byte;
  ctx              : THMAC_Context;
  HmacMac          : TMD5Digest;
begin
  copymemory(@TempConnotatedKey[ 0 ],@loginRequestHash[ 0 ], 16 );
  copymemory(@TempConnotatedKey[ 16 ],@smKey[ 0 ], 16 );

  hmac_MD5_init( ctx, @username[ 1 ], length( username ));
  hmac_MD5_update( ctx, @TempConnotatedKey[ 0 ], 32 );
  hmac_MD5_final( ctx, HmacMac );

  copymemory(@self.s2CKey[ 0 ],@HmacMac[ 0 ], 16 );

  result := self.s2CKey;
end;

Function TpwEmuLoginProtocolHandler.HashAnsiStringMD5( str: AnsiString ): THashKey;
var
  MD5context: THashcontext; // f�r MD5
  MD5       : TMD5Digest;
begin
  MD5Init( MD5context );
  MD5Update( MD5context, @str[ 1 ], length( str ));
  MD5Final( MD5context, MD5 );
  copymemory(@result[ 0 ],@MD5[ 0 ], 16 );
end;

Function TpwEmuLoginProtocolHandler.BuildHMACMD5( DataHash: THashKey; ChallengeKey: THashKey ): THashKey;
var
  HMACcontext: THMAC_Context; // f�r HMAC
  MD5D       : TMD5Digest;
begin
  hmac_MD5_init( HMACcontext, @DataHash, 16 );
  hmac_MD5_update( HMACcontext, @ChallengeKey[ 0 ], 16 );
  hmac_MD5_final( HMACcontext, MD5D );
  copymemory(@result[ 0 ],@MD5D[ 0 ], 16 );
end;

function TpwEmuLoginProtocolHandler.CompareHashKeys( HashKey1, HashKey2: THashKey ): Boolean;
var
  i: integer;
begin
  result := True;
  for i := 0 to 15 do
    if HashKey1[ i ] <> HashKey2[ i ]
    then
    begin
      result := False;
      exit;
    end;
end;

end.
