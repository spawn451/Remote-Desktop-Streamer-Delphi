unit video_encoder_vpx;

interface

uses
  Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Graphics, System.Types,Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Math, Vcl.StdCtrls,
  libyuv, vp8cx,vp8dx, vpx_decoder, vpx_encoder, vpx_codec, vpx_image;

type
  EVpxEncoderError = class(Exception);

  TVpxCodecType = (vctVP8, vctVP9);

// Simple frame header structure
TVpxFrameHeader = packed record
  Width: Word;
  Height: Word;
  Timestamp: Int64;
  DataSize: Cardinal;
  IsKeyFrame: Boolean;
  CodecFourCC: Cardinal;  // Add this to identify VP8/VP9
end;

  TVpxEncoderConfig = class
  private
    FConfig: vpx_codec_enc_cfg_t;
    FCodec: Pvpx_codec_ctx_t;
    FCodecType: TVpxCodecType;
  public
    constructor Create(Width, Height: Integer; ACodec: Pvpx_codec_ctx_t;
      ACodecType: TVpxCodecType = vctVP8);
    procedure ApplySettings;
    property Config: vpx_codec_enc_cfg_t read FConfig;
    property CodecType: TVpxCodecType read FCodecType;
  end;

  TImageConverter = class
  public
    class function BitmapToYUV420(const ABitmap: TBitmap): PByte;
  end;

  TVpxEncoder = class
  private
    FCodec: vpx_codec_ctx_t;
    FConfig: TVpxEncoderConfig;
    FInitialized: Boolean;
    FCodecType: TVpxCodecType;
    FFrameCount: Int64;
    FStartTime: Int64;

    procedure InitializeEncoder;
    function EncodeFrame(const YuvData: PByte; Width, Height: Integer;
      Timestamp: Int64 = 0): TMemoryStream;
    procedure WriteFrameHeader(AStream: TMemoryStream; Width, Height: Word;
      Timestamp: Int64; DataSize: Cardinal; IsKeyFrame: Boolean);
  public
    constructor Create(ACodecType: TVpxCodecType = vctVP8);
    destructor Destroy; override;
    function Encode(const ABitmap: TBitmap): TMemoryStream;
    property CodecType: TVpxCodecType read FCodecType write FCodecType;
  end;

implementation

{ ConvertARGBToI420 }

function AlignDimension(dim: Integer): Integer;
begin
  // Round up to nearest multiple of 2
  Result := (dim + 1) and not 1;
end;

function ConvertARGBToI420(BmpData: PByte; Width, Height: Integer): PByte;
var
  YUVSize: Integer;
  YuvData: PByte;
  AlignedWidth, AlignedHeight: Integer;
  TempBuffer: PByte;
  SrcStride, DstStride: Integer;
  Y: Integer;
begin
  // Calculate aligned dimensions
  AlignedWidth := AlignDimension(Width);
  AlignedHeight := AlignDimension(Height);

  // Calculate YUV size using aligned dimensions
  YUVSize := AlignedWidth * AlignedHeight * 3 div 2;

  // Allocate memory for YUV data
  GetMem(YuvData, YUVSize);

  if YuvData = nil then
  begin
    Result := nil;
    Exit;
  end;

  try
    // Initialize YUV buffer to zeros
    FillChar(YuvData^, YUVSize, 0);

    // If dimensions are already aligned, do direct conversion
    if (Width = AlignedWidth) and (Height = AlignedHeight) then
    begin
      ARGBToI420(BmpData, Width * 4,
        YuvData, AlignedWidth,
        YuvData + AlignedWidth * AlignedHeight, AlignedWidth div 2,
        YuvData + AlignedWidth * AlignedHeight + (AlignedWidth div 2) * (AlignedHeight div 2),
        AlignedWidth div 2,
        Width, Height);
    end
    else
    begin
      // Allocate temporary buffer for aligned data
      GetMem(TempBuffer, AlignedWidth * AlignedHeight * 4);
      try
        // Copy and pad the source data
        SrcStride := Width * 4;
        DstStride := AlignedWidth * 4;

        FillChar(TempBuffer^, AlignedWidth * AlignedHeight * 4, 0);

        for Y := 0 to Height - 1 do
        begin
          Move(PByte(NativeUInt(BmpData) + Y * SrcStride)^,
               PByte(NativeUInt(TempBuffer) + Y * DstStride)^,
               SrcStride);
        end;

        // Convert padded data
        ARGBToI420(TempBuffer, AlignedWidth * 4,
          YuvData, AlignedWidth,
          YuvData + AlignedWidth * AlignedHeight, AlignedWidth div 2,
          YuvData + AlignedWidth * AlignedHeight + (AlignedWidth div 2) * (AlignedHeight div 2),
          AlignedWidth div 2,
          AlignedWidth, AlignedHeight);

      finally
        FreeMem(TempBuffer);
      end;
    end;

    Result := YuvData;
  except
    FreeMem(YuvData);
    Result := nil;
  end;
end;

{ TImageConverter }

class function TImageConverter.BitmapToYUV420(const ABitmap: TBitmap): PByte;
var
  BmpData: PByte;
  Width, Height, Y: Integer;
  SrcLine, DstLine: PByte;
  BmpSize: Integer;

begin
  Result := nil;

  BmpData := nil;

  try
    Width := ABitmap.Width;
    Height := ABitmap.Height;
    BmpSize := Width * Height * 4; // 4 bytes per pixel for 32-bit
    GetMem(BmpData, BmpSize);

    // Copy bitmap data line by line
    DstLine := BmpData;
    for Y := 0 to Height - 1 do
    begin
      SrcLine := ABitmap.ScanLine[Y];
      Move(SrcLine^, DstLine^, Width * 4);
      Inc(DstLine, Width * 4);
    end;

    // Convert 32-bit bitmap to YUV 4:2:0
    Result := ConvertARGBToI420(BmpData, Width, Height);
    if Result = nil then
      raise EVpxEncoderError.Create('Failed to convert frame to YUV');
  finally
    if Assigned(BmpData) then
      FreeMem(BmpData);
  end;
end;


{ TVpxEncoderConfig }

constructor TVpxEncoderConfig.Create(Width, Height: Integer;
  ACodec: Pvpx_codec_ctx_t; ACodecType: TVpxCodecType = vctVP8);
var
  Res: vpx_codec_err_t;
  CodecIface: Pvpx_codec_iface_t; // Changed to pointer type
  AlignedWidth, AlignedHeight: Integer;
begin
  inherited Create;
  FCodec := ACodec;
  FCodecType := ACodecType;

  // Align dimensions first
  AlignedWidth := (Width + 1) and not 1;
  AlignedHeight := (Height + 1) and not 1;

  // Select codec interface based on type
  case FCodecType of
    vctVP8:
      CodecIface := vpx_codec_vp8_cx();
    vctVP9:
      CodecIface := vpx_codec_vp9_cx();
  else
    raise EVpxEncoderError.Create('Invalid codec type');
  end;

  Res := vpx_codec_err_t(vpx_codec_enc_config_default(CodecIface, @FConfig, 0));
  if Res <> VPX_CODEC_OK then
    raise EVpxEncoderError.CreateFmt
      ('Failed to get default encoder configuration: %s',
      [vpx_codec_err_to_string(Res)]);

  // Use aligned dimensions
  FConfig.g_w := AlignedWidth;
  FConfig.g_h := AlignedHeight;
  ApplySettings;
end;

procedure TVpxEncoderConfig.ApplySettings;
const
  kVp9I420ProfileNumber = 0;
begin
  with FConfig do
  begin
    case FCodecType of
      vctVP8:
        begin
          g_profile := 2;
        end;

      vctVP9:
        begin
          g_profile := kVp9I420ProfileNumber;
        end;
    end;

    // Common settings
    g_timebase.num := 1;
    g_timebase.den := 1000;
    g_pass := VPX_RC_ONE_PASS;
    g_lag_in_frames := 0;
    g_error_resilient := VPX_ERROR_RESILIENT_DEFAULT;

    // Performance settings
    g_threads := (Max(1, System.CPUCount + 1) div 2);
    rc_dropframe_thresh := 0;

    // Keyframe settings
    kf_min_dist := 10000;
    kf_max_dist := 10000;
    kf_mode := VPX_KF_DISABLED;

    // Bitrate and quality settings
    //rc_target_bitrate := 10000;
    rc_target_bitrate := 1469;
    rc_end_usage := VPX_CBR;
    rc_undershoot_pct := 100;
    rc_overshoot_pct := 15;

     {
      1. Quality::Best
          q_min = 12: Minimum quantizer, aiming for very high quality
          q_max = 25: Maximum quantizer, allowing some compression but still maintaining quality

      2. Quality::Balanced

          q_min = 12: Same minimum quantizer as Best, ensuring good quality
          q_max = 35: Higher maximum quantizer, allowing more compression than Best

      3. Quality::Low

          q_min = 18: Higher minimum quantizer, reducing quality to allow more compression
          q_max = 45: Much higher maximum quantizer, enabling significant compression.
     }

     rc_min_quantizer := 12;
     rc_max_quantizer := 25;

  end;
end;

{ FrameWriter }

procedure TVpxEncoder.WriteFrameHeader(AStream: TMemoryStream; Width, Height: Word;
  Timestamp: Int64; DataSize: Cardinal; IsKeyFrame: Boolean);
var
  Header: TVpxFrameHeader;
begin
  case FCodecType of
    vctVP8: Header.CodecFourCC := $30385056;  // 'VP80'
    vctVP9: Header.CodecFourCC := $30395056;  // 'VP90'
    else raise EVpxEncoderError.Create('Invalid codec type');
  end;

  Header.Width := Width;
  Header.Height := Height;
  Header.Timestamp := Timestamp;
  Header.DataSize := DataSize;  // This should be just the frame data size, not including header
  Header.IsKeyFrame := IsKeyFrame;

  AStream.WriteBuffer(Header, SizeOf(TVpxFrameHeader));
end;


{ TVpxEncoder }

constructor TVpxEncoder.Create(ACodecType: TVpxCodecType = vctVP8);
begin
  inherited Create;
  FillChar(FCodec, SizeOf(FCodec), 0);
  FInitialized := False;
  FCodecType := ACodecType;
  FStartTime := GetTickCount64;
  FFrameCount := 0;
end;

destructor TVpxEncoder.Destroy;
begin
  if FInitialized then
    vpx_codec_destroy(@FCodec);
  FConfig.Free;
  inherited;
end;

procedure TVpxEncoder.InitializeEncoder;
const
  kVp9AqModeCyclicRefresh = 3;
var
  Res: vpx_codec_err_t;
  CodecIface: Pvpx_codec_iface_t; // Changed to pointer type
begin
  if not Assigned(FConfig) then
    raise EVpxEncoderError.Create('Encoder configuration not set');

  // Select codec interface based on type
  case FCodecType of
    vctVP8:
      CodecIface := vpx_codec_vp8_cx();
    vctVP9:
      CodecIface := vpx_codec_vp9_cx();
  else
    raise EVpxEncoderError.Create('Invalid codec type');
  end;

  Res := vpx_codec_err_t(vpx_codec_enc_init(@FCodec, CodecIface,
    @FConfig.Config, 0));
  if Res <> VPX_CODEC_OK then
    raise EVpxEncoderError.CreateFmt('Failed to initialize encoder: %s',
      [vpx_codec_err_to_string(Res)]);

  // Apply codec-specific controls
  case FCodecType of
    vctVP8:
      begin
        // Screen content mode is important for desktop capture
        Res := vpx_codec_err_t(vpx_codec_control_(@FCodec,
          Integer(VP8E_SET_SCREEN_CONTENT_MODE), 1));
        if Res <> VPX_CODEC_OK then
          raise EVpxEncoderError.CreateFmt
            ('VP8E_SET_SCREEN_CONTENT_MODE failed: %s',
            [vpx_codec_err_to_string(Res)]);
        // Lower noise sensitivity for better performance
        Res := vpx_codec_err_t(vpx_codec_control_(@FCodec,
          Integer(VP8E_SET_NOISE_SENSITIVITY), 0));
        if Res <> VPX_CODEC_OK then
          raise EVpxEncoderError.CreateFmt
            ('vpx_codec_control(VP8E_SET_NOISE_SENSITIVITY) failed: %s',
            [vpx_codec_err_to_string(Res)]);
        // Token partitions for better parallel processing
        Res := vpx_codec_err_t(vpx_codec_control_(@FCodec,
          Integer(VP8E_SET_TOKEN_PARTITIONS), 3));
        if Res <> VPX_CODEC_OK then
          raise EVpxEncoderError.CreateFmt
            ('VP8E_SET_TOKEN_PARTITIONS failed: %s',
            [vpx_codec_err_to_string(Res)]);
        // Maximum CPU optimization for VP8
        Res := vpx_codec_err_t(vpx_codec_control_(@FCodec,
          Integer(VP8E_SET_CPUUSED), 16));
        if Res <> VPX_CODEC_OK then
          raise EVpxEncoderError.CreateFmt('VP8E_SET_CPUUSED failed: %s',
            [vpx_codec_err_to_string(Res)]);
      end;

    vctVP9:
      begin
        // Best CPU performance setting for VP9
        Res := vpx_codec_err_t(vpx_codec_control_(@FCodec,
          Integer(VP8E_SET_CPUUSED), 6));
        if Res <> VPX_CODEC_OK then
          raise EVpxEncoderError.CreateFmt('VP8E_SET_CPUUSED failed: %s',
            [vpx_codec_err_to_string(Res)]);
        // Screen content optimization
        Res := vpx_codec_err_t(vpx_codec_control_(@FCodec,
          Integer(VP9E_SET_TUNE_CONTENT), VP9E_CONTENT_SCREEN));
        if Res <> VPX_CODEC_OK then
          raise EVpxEncoderError.CreateFmt('VP9E_SET_TUNE_CONTENT failed: %s',
            [vpx_codec_err_to_string(Res)]);
        // Minimal noise sensitivity
        Res := vpx_codec_err_t(vpx_codec_control_(@FCodec,
          Integer(VP9E_SET_NOISE_SENSITIVITY), 0));
        if Res <> VPX_CODEC_OK then
          raise EVpxEncoderError.CreateFmt
            ('VP9E_SET_NOISE_SENSITIVITY failed: %s',
            [vpx_codec_err_to_string(Res)]);
        // Cyclic refresh for better quality
        Res := vpx_codec_err_t(vpx_codec_control_(@FCodec,
          Integer(VP9E_SET_AQ_MODE), kVp9AqModeCyclicRefresh));
        if Res <> VPX_CODEC_OK then
          raise EVpxEncoderError.CreateFmt('VP9E_SET_AQ_MODE failed: %s',
            [vpx_codec_err_to_string(Res)]);
      end;
  end;

  FInitialized := True;
end;

function TVpxEncoder.EncodeFrame(const YuvData: PByte; Width, Height: Integer;
  Timestamp: Int64): TMemoryStream;
var
  Raw: vpx_image_t;
  Res: vpx_codec_err_t;
  Pkt: PVpxCodecCxPkt;
  Iter: vpx_codec_iter_t;
  IsKeyFrame: Boolean;
begin
  Result := TMemoryStream.Create;
  try
    if YuvData = nil then
      raise EVpxEncoderError.Create('YUV data is nil');

    if (Width <= 0) or (Height <= 0) then
      raise EVpxEncoderError.Create('Invalid dimensions');

    if not FInitialized then
      raise EVpxEncoderError.Create('Encoder not initialized');

    FillChar(Raw, SizeOf(Raw), 0);

    if vpx_img_wrap(@Raw, VPX_IMG_FMT_I420, Width, Height, 1, YuvData) = nil then
      raise EVpxEncoderError.Create('Failed to wrap YUV image');

    Res := vpx_codec_err_t(vpx_codec_encode(@FCodec, @Raw, Timestamp, 1, 0,
      VPX_DL_REALTIME));

    if Res <> VPX_CODEC_OK then
    begin
      var ErrorMsg := string(vpx_codec_error(@FCodec));
      var ErrorDetail := string(vpx_codec_error_detail(@FCodec));
      raise EVpxEncoderError.CreateFmt('Encode failed: %s. Details: %s',
        [ErrorMsg, ErrorDetail]);
    end;

    Iter := nil;
    try
      Pkt := vpx_codec_get_cx_data(@FCodec, @Iter);
      while Pkt <> nil do
      begin
        if Pkt^.kind = VPX_CODEC_CX_FRAME_PKT then
        begin
          if (Pkt^.frame.buf = nil) or (Pkt^.frame.sz = 0) then
            raise EVpxEncoderError.Create('Invalid packet data received');

          IsKeyFrame := (Pkt^.frame.flags and VPX_FRAME_IS_KEY) <> 0;

          // Write our simple header
          WriteFrameHeader(Result, Width, Height, Timestamp, Pkt^.frame.sz, IsKeyFrame);

          // Write the raw frame data
          Result.WriteBuffer(Pkt^.frame.buf^, Pkt^.frame.sz);
          Break;
        end;
        Pkt := vpx_codec_get_cx_data(@FCodec, @Iter);
      end;

      if Result.Size <= SizeOf(TVpxFrameHeader) then
        raise EVpxEncoderError.Create('No valid packets received from encoder');

    except
      on E: Exception do
        raise EVpxEncoderError.CreateFmt('Error processing encoded frame: %s',
          [E.Message]);
    end;

    Result.Position := 0;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function TVpxEncoder.Encode(const ABitmap: TBitmap): TMemoryStream;
var
  YuvData: PByte;
  AlignedWidth, AlignedHeight: Integer;
begin
  Result := nil;
  YuvData := nil;

  if ABitmap = nil then
    raise EVpxEncoderError.Create('Input bitmap is nil');

  if ABitmap.PixelFormat <> pf32bit then
    raise EVpxEncoderError.Create('Bitmap must be 32-bit format');

try
    AlignedWidth := (ABitmap.Width + 1) and not 1;
    AlignedHeight := (ABitmap.Height + 1) and not 1;

    // Check if we need to reinitialize the encoder due to size change
    if Assigned(FConfig) and ((FConfig.Config.g_w <> AlignedWidth) or
      (FConfig.Config.g_h <> AlignedHeight)) then
    begin
      if FInitialized then
        vpx_codec_destroy(@FCodec);
      FConfig.Free;
      FConfig := nil;
      FInitialized := False;
    end;

    // Create and initialize encoder if needed
    if not Assigned(FConfig) then
    begin
      FConfig := TVpxEncoderConfig.Create(ABitmap.Width, ABitmap.Height,
        @FCodec, FCodecType);
      InitializeEncoder;
    end;

    // Convert bitmap to YUV
    YuvData := TImageConverter.BitmapToYUV420(ABitmap);
    if not Assigned(YuvData) then
      raise EVpxEncoderError.Create('YUV conversion failed');

    var CurrentTime := GetTickCount64 - FStartTime;
    Result := EncodeFrame(YuvData, AlignedWidth, AlignedHeight, CurrentTime);
    Inc(FFrameCount);

  finally
    if Assigned(YuvData) then
      FreeMem(YuvData);
  end;
end;

end.
