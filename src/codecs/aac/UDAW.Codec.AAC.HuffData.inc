{ ====================================================================
  UDAW.Codec.AAC.HuffData.inc  -  AAC Huffman codebook data

  Twelve codebooks feed the AAC spectral / scalefactor decode:

     book 0  : the scalefactor codebook          (ISO/IEC 14496-3 Table 4.A.1)
     book 1  : spectral, 4 coeff, signed,  LAV 1 (Table 4.A.2)   81 codewords
     book 2  : spectral, 4 coeff, signed,  LAV 1 (Table 4.A.3)   81
     book 3  : spectral, 4 coeff, unsigned,LAV 2 (Table 4.A.4)   81
     book 4  : spectral, 4 coeff, unsigned,LAV 2 (Table 4.A.5)   81
     book 5  : spectral, 2 coeff, signed,  LAV 4 (Table 4.A.6)   81
     book 6  : spectral, 2 coeff, signed,  LAV 4 (Table 4.A.7)   81
     book 7  : spectral, 2 coeff, unsigned,LAV 7 (Table 4.A.8)   64
     book 8  : spectral, 2 coeff, unsigned,LAV 7 (Table 4.A.9)   64
     book 9  : spectral, 2 coeff, unsigned,LAV 12(Table 4.A.10) 169
     book 10 : spectral, 2 coeff, unsigned,LAV 12(Table 4.A.11) 169
     book 11 : spectral, 2 coeff, unsigned,LAV 16+ESC(Table4.A.12)289

  Representation (mirrors the Phase 15 MP3 tables):

    * a per-book LENGTH array (Huffman code length for codeword i), where i is
      the natural nested enumeration of the tuple:
         4-coeff book:  i = ((w*M + x)*M + y)*M + z
         2-coeff book:  i = y*M + z
      with M = ModVal (= LavMax+1 for an unsigned book's magnitude-only tuple,
      = 2*LavMax+1 for a signed book's symmetric tuple - see AAC_HCB_META).
    * codewords are pasted verbatim from the reference (not canonically
      re-derived): AacApplyBookCodes overwrites the canonical codes built from
      the lengths with the exact reference column for every book, so the
      bitstream codeword assignment matches a real encoder bit-for-bit.

  Populated 2026 from FFmpeg libavcodec/aactab.c (BSD/LGPL, values only - no
  code copied): ff_aac_scalefactor_bits/ff_aac_scalefactor_code (book 0) and
  bits1..bits11 / codes1..codes11 (books 1-11), which are FFmpeg's direct
  transcription of ISO/IEC 14496-3:2009 Tables 4.A.1 .. 4.A.12. The natural
  nested-tuple order assumed above was verified against FFmpeg's companion
  literal-value tables (codebook_vector0 for book 1: entry 0 = (-1,-1,-1,-1),
  entry 1 = (-1,-1,-1,0), ... - exactly the nested loop with the last
  coefficient fastest; codebook_vector2 for book 3: entry 0 = (0,0,0,0),
  entry 1 = (0,0,0,1), entry 2 = (0,0,0,2) - confirming an UNSIGNED book's
  per-axis range is 0..LavMax (LavMax+1 values), not the symmetric
  2*LavMax+1 a signed book uses).

  Every book's Kraft sum (sum of 2^-length over all codewords) was verified
  to equal exactly 1.0 before this file was written, and HuffBooksSelfCheck
  re-verifies the same invariant (plus the ISO codeword counts) at runtime.
  ==================================================================== }

{ Book metadata: Dim, ModVal, LavMax, Signed(0/1), expected count.
  ModVal is the per-axis cardinality UnpackTuple divides by: LavMax+1 for an
  unsigned book (tuple values are magnitudes 0..LavMax, sign read separately
  from the bitstream - see UDAW.Codec.AAC.Decoder), or 2*LavMax+1 for a
  signed book (the tuple value's sign is carried directly by the codeword,
  base-shifted by (ModVal-1) div 2 in UnpackTuple). }
const
  AAC_HCB_META: array[0..11, 0..4] of Integer = (
    (1,  121, 60, 0, 121),   // 0  scalefactor book (Decode() used directly, Dim/ModVal unused)
    (4,   3,  1, 1,  81),    // 1  signed:   ModVal = 2*1+1 = 3
    (4,   3,  1, 1,  81),    // 2  signed:   ModVal = 2*1+1 = 3
    (4,   3,  2, 0,  81),    // 3  unsigned: ModVal = 2+1   = 3
    (4,   3,  2, 0,  81),    // 4  unsigned: ModVal = 2+1   = 3
    (2,   9,  4, 1,  81),    // 5  signed:   ModVal = 2*4+1 = 9
    (2,   9,  4, 1,  81),    // 6  signed:   ModVal = 2*4+1 = 9
    (2,   8,  7, 0,  64),    // 7  unsigned: ModVal = 7+1   = 8
    (2,   8,  7, 0,  64),    // 8  unsigned: ModVal = 7+1   = 8
    (2,  13, 12, 0, 169),    // 9  unsigned: ModVal = 12+1  = 13
    (2,  13, 12, 0, 169),    // 10 unsigned: ModVal = 12+1  = 13
    (2,  17, 16, 0, 289)     // 11 unsigned: ModVal = 16+1  = 17 (ESC on |v|=16)
  );

type
  TAacByteArr = array of Byte;

{ ---- real-data hooks, populated from the FFmpeg transcription above ---- }

procedure AacGetBookBits(ABook: Integer; var ABits: TAacByteArr);
begin
  case ABook of
    0:
      ABits := TAacByteArr.Create(
        18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 18,
        19, 18, 17, 17, 16, 17, 16, 16, 16, 16, 15, 15, 14, 14, 14, 14, 14, 14, 13, 13,
        12, 12, 12, 11, 12, 11, 10, 10, 10, 9, 9, 8, 8, 8, 7, 6, 6, 5, 4, 3,
        1, 4, 4, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 10, 11, 11, 11, 11, 12,
        12, 13, 13, 13, 14, 14, 16, 15, 16, 15, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19,
        19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
        19
      );
    1:
      ABits := TAacByteArr.Create(
        11, 9, 11, 10, 7, 10, 11, 9, 11, 10, 7, 10, 7, 5, 7, 9, 7, 10, 11, 9,
        11, 9, 7, 9, 11, 9, 11, 9, 7, 9, 7, 5, 7, 9, 7, 9, 7, 5, 7, 5,
        1, 5, 7, 5, 7, 9, 7, 9, 7, 5, 7, 9, 7, 9, 11, 9, 11, 9, 7, 9,
        11, 9, 11, 10, 7, 9, 7, 5, 7, 9, 7, 10, 11, 9, 11, 10, 7, 9, 11, 9,
        11
      );
    2:
      ABits := TAacByteArr.Create(
        9, 7, 9, 8, 6, 8, 9, 8, 9, 8, 6, 7, 6, 5, 6, 7, 6, 8, 9, 7,
        8, 8, 6, 8, 9, 7, 9, 8, 6, 7, 6, 5, 6, 7, 6, 8, 6, 5, 6, 5,
        3, 5, 6, 5, 6, 8, 6, 7, 6, 5, 6, 8, 6, 8, 9, 7, 9, 8, 6, 8,
        8, 7, 9, 8, 6, 7, 6, 4, 6, 8, 6, 7, 9, 7, 9, 7, 6, 8, 9, 7,
        9
      );
    3:
      ABits := TAacByteArr.Create(
        1, 4, 8, 4, 5, 8, 9, 9, 10, 4, 6, 9, 6, 6, 9, 9, 9, 10, 9, 10,
        13, 9, 9, 11, 11, 10, 12, 4, 6, 10, 6, 7, 10, 10, 10, 12, 5, 7, 11, 6,
        7, 10, 9, 9, 11, 9, 10, 13, 8, 9, 12, 10, 11, 12, 8, 10, 15, 9, 11, 15,
        13, 14, 16, 8, 10, 14, 9, 10, 14, 12, 12, 15, 11, 12, 16, 10, 11, 15, 12, 12,
        15
      );
    4:
      ABits := TAacByteArr.Create(
        4, 5, 8, 5, 4, 8, 9, 8, 11, 5, 5, 8, 5, 4, 8, 8, 7, 10, 9, 8,
        11, 8, 8, 10, 11, 10, 11, 4, 5, 8, 4, 4, 8, 8, 8, 10, 4, 4, 8, 4,
        4, 7, 8, 7, 9, 8, 8, 10, 7, 7, 9, 10, 9, 10, 8, 8, 11, 8, 7, 10,
        11, 10, 12, 8, 7, 10, 7, 7, 9, 10, 9, 11, 11, 10, 12, 10, 9, 11, 11, 10,
        11
      );
    5:
      ABits := TAacByteArr.Create(
        13, 12, 11, 11, 10, 11, 11, 12, 13, 12, 11, 10, 9, 8, 9, 10, 11, 12, 12, 10,
        9, 8, 7, 8, 9, 10, 11, 11, 9, 8, 5, 4, 5, 8, 9, 11, 10, 8, 7, 4,
        1, 4, 7, 8, 11, 11, 9, 8, 5, 4, 5, 8, 9, 11, 11, 10, 9, 8, 7, 8,
        9, 10, 11, 12, 11, 10, 9, 8, 9, 10, 11, 12, 13, 12, 12, 11, 10, 10, 11, 12,
        13
      );
    6:
      ABits := TAacByteArr.Create(
        11, 10, 9, 9, 9, 9, 9, 10, 11, 10, 9, 8, 7, 7, 7, 8, 9, 10, 9, 8,
        6, 6, 6, 6, 6, 8, 9, 9, 7, 6, 4, 4, 4, 6, 7, 9, 9, 7, 6, 4,
        4, 4, 6, 7, 9, 9, 7, 6, 4, 4, 4, 6, 7, 9, 9, 8, 6, 6, 6, 6,
        6, 8, 9, 10, 9, 8, 7, 7, 7, 7, 8, 10, 11, 10, 9, 9, 9, 9, 9, 10,
        11
      );
    7:
      ABits := TAacByteArr.Create(
        1, 3, 6, 7, 8, 9, 10, 11, 3, 4, 6, 7, 8, 8, 9, 9, 6, 6, 7, 8,
        8, 9, 9, 10, 7, 7, 8, 8, 9, 9, 10, 10, 8, 8, 9, 9, 10, 10, 10, 11,
        9, 8, 9, 9, 10, 10, 11, 11, 10, 9, 9, 10, 10, 11, 12, 12, 11, 10, 10, 10,
        11, 11, 12, 12
      );
    8:
      ABits := TAacByteArr.Create(
        5, 4, 5, 6, 7, 8, 9, 10, 4, 3, 4, 5, 6, 7, 7, 8, 5, 4, 4, 5,
        6, 7, 7, 8, 6, 5, 5, 6, 6, 7, 8, 8, 7, 6, 6, 6, 7, 7, 8, 9,
        8, 7, 6, 7, 7, 8, 8, 10, 9, 7, 7, 8, 8, 8, 9, 9, 10, 8, 8, 8,
        9, 9, 9, 10
      );
    9:
      ABits := TAacByteArr.Create(
        1, 3, 6, 8, 9, 10, 10, 11, 11, 12, 12, 13, 13, 3, 4, 6, 7, 8, 8, 9,
        10, 10, 10, 11, 12, 12, 6, 6, 7, 8, 8, 9, 10, 10, 10, 11, 12, 12, 12, 8,
        7, 8, 9, 9, 10, 10, 11, 11, 11, 12, 12, 13, 9, 8, 9, 9, 10, 10, 11, 11,
        11, 12, 12, 12, 13, 10, 9, 9, 10, 11, 11, 11, 12, 11, 12, 12, 13, 13, 11, 9,
        10, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 11, 10, 10, 11, 11, 12, 12, 13, 13,
        13, 13, 13, 13, 11, 10, 10, 11, 11, 11, 12, 12, 13, 13, 14, 13, 14, 11, 10, 11,
        11, 12, 12, 12, 12, 13, 13, 14, 14, 14, 12, 11, 11, 12, 12, 12, 13, 13, 13, 14,
        14, 14, 15, 12, 11, 12, 12, 12, 13, 13, 13, 13, 14, 14, 15, 15, 13, 12, 12, 12,
        13, 13, 13, 13, 14, 14, 14, 14, 15
      );
    10:
      ABits := TAacByteArr.Create(
        6, 5, 6, 6, 7, 8, 9, 10, 10, 10, 11, 11, 12, 5, 4, 4, 5, 6, 7, 7,
        8, 8, 9, 10, 10, 11, 6, 4, 5, 5, 6, 6, 7, 8, 8, 9, 9, 10, 10, 6,
        5, 5, 5, 6, 7, 7, 8, 8, 9, 9, 10, 10, 7, 6, 6, 6, 6, 7, 7, 8,
        8, 9, 9, 10, 10, 8, 7, 6, 7, 7, 7, 8, 8, 8, 9, 10, 10, 11, 9, 7,
        7, 7, 7, 8, 8, 9, 9, 9, 10, 10, 11, 9, 8, 8, 8, 8, 8, 9, 9, 9,
        10, 10, 11, 11, 9, 8, 8, 8, 8, 8, 9, 9, 10, 10, 10, 11, 11, 10, 9, 9,
        9, 9, 9, 9, 10, 10, 10, 11, 11, 12, 10, 9, 9, 9, 9, 10, 10, 10, 10, 11,
        11, 11, 12, 11, 10, 9, 10, 10, 10, 10, 10, 11, 11, 11, 11, 12, 11, 10, 10, 10,
        10, 10, 10, 11, 11, 12, 12, 12, 12
      );
    11:
      ABits := TAacByteArr.Create(
        4, 5, 6, 7, 8, 8, 9, 10, 10, 10, 11, 11, 12, 11, 12, 12, 10, 5, 4, 5,
        6, 7, 7, 8, 8, 9, 9, 9, 10, 10, 10, 10, 11, 8, 6, 5, 5, 6, 7, 7,
        8, 8, 8, 9, 9, 9, 10, 10, 10, 10, 8, 7, 6, 6, 6, 7, 7, 8, 8, 8,
        9, 9, 9, 10, 10, 10, 10, 8, 8, 7, 7, 7, 7, 8, 8, 8, 8, 9, 9, 9,
        10, 10, 10, 10, 8, 8, 7, 7, 7, 7, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10,
        10, 8, 9, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 10, 10, 10, 10, 10, 8, 9,
        8, 8, 8, 8, 8, 8, 9, 9, 9, 10, 10, 10, 10, 10, 10, 8, 10, 9, 8, 8,
        9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 11, 8, 10, 9, 9, 9, 9, 9, 9,
        9, 10, 10, 10, 10, 10, 10, 11, 11, 8, 11, 9, 9, 9, 9, 9, 9, 10, 10, 10,
        10, 10, 11, 10, 11, 11, 8, 11, 10, 9, 9, 10, 9, 10, 10, 10, 10, 10, 11, 11,
        11, 11, 11, 8, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11,
        9, 11, 10, 9, 9, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 9, 11, 10,
        10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 9, 12, 10, 10, 10, 10,
        10, 10, 10, 11, 11, 11, 11, 11, 11, 12, 12, 9, 9, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 9, 5
      );
  end;
end;

procedure AacApplyBookCodes(ABook: Integer; var ACodes: array of Cardinal);
var
  ref: TArray<Cardinal>;
  i: Integer;
begin
  case ABook of
    0:
      ref := TArray<Cardinal>.Create(
        $3FFE8, $3FFE6, $3FFE7, $3FFE5, $7FFF5, $7FFF1, $7FFED, $7FFF6, $7FFEE, $7FFEF,
        $7FFF0, $7FFFC, $7FFFD, $7FFFF, $7FFFE, $7FFF7, $7FFF8, $7FFFB, $7FFF9, $3FFE4,
        $7FFFA, $3FFE3, $1FFEF, $1FFF0, $FFF5, $1FFEE, $FFF2, $FFF3, $FFF4, $FFF1,
        $7FF6, $7FF7, $3FF9, $3FF5, $3FF7, $3FF3, $3FF6, $3FF2, $1FF7, $1FF5,
        $FF9, $FF7, $FF6, $7F9, $FF4, $7F8, $3F9, $3F7, $3F5, $1F8,
        $1F7, $FA, $F8, $F6, $79, $3A, $38, $1A, $B, $4,
        $0, $A, $C, $1B, $39, $3B, $78, $7A, $F7, $F9,
        $1F6, $1F9, $3F4, $3F6, $3F8, $7F5, $7F4, $7F6, $7F7, $FF5,
        $FF8, $1FF4, $1FF6, $1FF8, $3FF8, $3FF4, $FFF0, $7FF4, $FFF6, $7FF5,
        $3FFE2, $7FFD9, $7FFDA, $7FFDB, $7FFDC, $7FFDD, $7FFDE, $7FFD8, $7FFD2, $7FFD3,
        $7FFD4, $7FFD5, $7FFD6, $7FFF2, $7FFDF, $7FFE7, $7FFE8, $7FFE9, $7FFEA, $7FFEB,
        $7FFE6, $7FFE0, $7FFE1, $7FFE2, $7FFE3, $7FFE4, $7FFE5, $7FFD7, $7FFEC, $7FFF4,
        $7FFF3
      );
    1:
      ref := TArray<Cardinal>.Create(
        $7F8, $1F1, $7FD, $3F5, $68, $3F0, $7F7, $1EC, $7F5, $3F1,
        $72, $3F4, $74, $11, $76, $1EB, $6C, $3F6, $7FC, $1E1,
        $7F1, $1F0, $61, $1F6, $7F2, $1EA, $7FB, $1F2, $69, $1ED,
        $77, $17, $6F, $1E6, $64, $1E5, $67, $15, $62, $12,
        $0, $14, $65, $16, $6D, $1E9, $63, $1E4, $6B, $13,
        $71, $1E3, $70, $1F3, $7FE, $1E7, $7F3, $1EF, $60, $1EE,
        $7F0, $1E2, $7FA, $3F3, $6A, $1E8, $75, $10, $73, $1F4,
        $6E, $3F7, $7F6, $1E0, $7F9, $3F2, $66, $1F5, $7FF, $1F7,
        $7F4
      );
    2:
      ref := TArray<Cardinal>.Create(
        $1F3, $6F, $1FD, $EB, $23, $EA, $1F7, $E8, $1FA, $F2,
        $2D, $70, $20, $6, $2B, $6E, $28, $E9, $1F9, $66,
        $F8, $E7, $1B, $F1, $1F4, $6B, $1F5, $EC, $2A, $6C,
        $2C, $A, $27, $67, $1A, $F5, $24, $8, $1F, $9,
        $0, $7, $1D, $B, $30, $EF, $1C, $64, $1E, $C,
        $29, $F3, $2F, $F0, $1FC, $71, $1F2, $F4, $21, $E6,
        $F7, $68, $1F8, $EE, $22, $65, $31, $2, $26, $ED,
        $25, $6A, $1FB, $72, $1FE, $69, $2E, $F6, $1FF, $6D,
        $1F6
      );
    3:
      ref := TArray<Cardinal>.Create(
        $0, $9, $EF, $B, $19, $F0, $1EB, $1E6, $3F2, $A,
        $35, $1EF, $34, $37, $1E9, $1ED, $1E7, $3F3, $1EE, $3ED,
        $1FFA, $1EC, $1F2, $7F9, $7F8, $3F8, $FF8, $8, $38, $3F6,
        $36, $75, $3F1, $3EB, $3EC, $FF4, $18, $76, $7F4, $39,
        $74, $3EF, $1F3, $1F4, $7F6, $1E8, $3EA, $1FFC, $F2, $1F1,
        $FFB, $3F5, $7F3, $FFC, $EE, $3F7, $7FFE, $1F0, $7F5, $7FFD,
        $1FFB, $3FFA, $FFFF, $F1, $3F0, $3FFC, $1EA, $3EE, $3FFB, $FF6,
        $FFA, $7FFC, $7F2, $FF5, $FFFE, $3F4, $7F7, $7FFB, $FF7, $FF9,
        $7FFA
      );
    4:
      ref := TArray<Cardinal>.Create(
        $7, $16, $F6, $18, $8, $EF, $1EF, $F3, $7F8, $19,
        $17, $ED, $15, $1, $E2, $F0, $70, $3F0, $1EE, $F1,
        $7FA, $EE, $E4, $3F2, $7F6, $3EF, $7FD, $5, $14, $F2,
        $9, $4, $E5, $F4, $E8, $3F4, $6, $2, $E7, $3,
        $0, $6B, $E3, $69, $1F3, $EB, $E6, $3F6, $6E, $6A,
        $1F4, $3EC, $1F0, $3F9, $F5, $EC, $7FB, $EA, $6F, $3F7,
        $7F9, $3F3, $FFF, $E9, $6D, $3F8, $6C, $68, $1F5, $3EE,
        $1F2, $7F4, $7F7, $3F1, $FFE, $3ED, $1F1, $7F5, $7FE, $3F5,
        $7FC
      );
    5:
      ref := TArray<Cardinal>.Create(
        $1FFF, $FF7, $7F4, $7E8, $3F1, $7EE, $7F9, $FF8, $1FFD, $FFD,
        $7F1, $3E8, $1E8, $F0, $1EC, $3EE, $7F2, $FFA, $FF4, $3EF,
        $1F2, $E8, $70, $EC, $1F0, $3EA, $7F3, $7EB, $1EB, $EA,
        $1A, $8, $19, $EE, $1EF, $7ED, $3F0, $F2, $73, $B,
        $0, $A, $71, $F3, $7E9, $7EF, $1EE, $EF, $18, $9,
        $1B, $EB, $1E9, $7EC, $7F6, $3EB, $1F3, $ED, $72, $E9,
        $1F1, $3ED, $7F7, $FF6, $7F0, $3E9, $1ED, $F1, $1EA, $3EC,
        $7F8, $FF9, $1FFC, $FFC, $FF5, $7EA, $3F3, $3F2, $7F5, $FFB,
        $1FFE
      );
    6:
      ref := TArray<Cardinal>.Create(
        $7FE, $3FD, $1F1, $1EB, $1F4, $1EA, $1F0, $3FC, $7FD, $3F6,
        $1E5, $EA, $6C, $71, $68, $F0, $1E6, $3F7, $1F3, $EF,
        $32, $27, $28, $26, $31, $EB, $1F7, $1E8, $6F, $2E,
        $8, $4, $6, $29, $6B, $1EE, $1EF, $72, $2D, $2,
        $0, $3, $2F, $73, $1FA, $1E7, $6E, $2B, $7, $1,
        $5, $2C, $6D, $1EC, $1F9, $EE, $30, $24, $2A, $25,
        $33, $EC, $1F2, $3F8, $1E4, $ED, $6A, $70, $69, $74,
        $F1, $3FA, $7FF, $3F9, $1F6, $1ED, $1F8, $1E9, $1F5, $3FB,
        $7FC
      );
    7:
      ref := TArray<Cardinal>.Create(
        $0, $5, $37, $74, $F2, $1EB, $3ED, $7F7, $4, $C,
        $35, $71, $EC, $EE, $1EE, $1F5, $36, $34, $72, $EA,
        $F1, $1E9, $1F3, $3F5, $73, $70, $EB, $F0, $1F1, $1F0,
        $3EC, $3FA, $F3, $ED, $1E8, $1EF, $3EF, $3F1, $3F9, $7FB,
        $1ED, $EF, $1EA, $1F2, $3F3, $3F8, $7F9, $7FC, $3EE, $1EC,
        $1F4, $3F4, $3F7, $7F8, $FFD, $FFE, $7F6, $3F0, $3F2, $3F6,
        $7FA, $7FD, $FFC, $FFF
      );
    8:
      ref := TArray<Cardinal>.Create(
        $E, $5, $10, $30, $6F, $F1, $1FA, $3FE, $3, $0,
        $4, $12, $2C, $6A, $75, $F8, $F, $2, $6, $14,
        $2E, $69, $72, $F5, $2F, $11, $13, $2A, $32, $6C,
        $EC, $FA, $71, $2B, $2D, $31, $6D, $70, $F2, $1F9,
        $EF, $68, $33, $6B, $6E, $EE, $F9, $3FC, $1F8, $74,
        $73, $ED, $F0, $F6, $1F6, $1FD, $3FD, $F3, $F4, $F7,
        $1F7, $1FB, $1FC, $3FF
      );
    9:
      ref := TArray<Cardinal>.Create(
        $0, $5, $37, $E7, $1DE, $3CE, $3D9, $7C8, $7CD, $FC8,
        $FDD, $1FE4, $1FEC, $4, $C, $35, $72, $EA, $ED, $1E2,
        $3D1, $3D3, $3E0, $7D8, $FCF, $FD5, $36, $34, $71, $E8,
        $EC, $1E1, $3CF, $3DD, $3DB, $7D0, $FC7, $FD4, $FE4, $E6,
        $70, $E9, $1DD, $1E3, $3D2, $3DC, $7CC, $7CA, $7DE, $FD8,
        $FEA, $1FDB, $1DF, $EB, $1DC, $1E6, $3D5, $3DE, $7CB, $7DD,
        $7DC, $FCD, $FE2, $FE7, $1FE1, $3D0, $1E0, $1E4, $3D6, $7C5,
        $7D1, $7DB, $FD2, $7E0, $FD9, $FEB, $1FE3, $1FE9, $7C4, $1E5,
        $3D7, $7C6, $7CF, $7DA, $FCB, $FDA, $FE3, $FE9, $1FE6, $1FF3,
        $1FF7, $7D3, $3D8, $3E1, $7D4, $7D9, $FD3, $FDE, $1FDD, $1FD9,
        $1FE2, $1FEA, $1FF1, $1FF6, $7D2, $3D4, $3DA, $7C7, $7D7, $7E2,
        $FCE, $FDB, $1FD8, $1FEE, $3FF0, $1FF4, $3FF2, $7E1, $3DF, $7C9,
        $7D6, $FCA, $FD0, $FE5, $FE6, $1FEB, $1FEF, $3FF3, $3FF4, $3FF5,
        $FE0, $7CE, $7D5, $FC6, $FD1, $FE1, $1FE0, $1FE8, $1FF0, $3FF1,
        $3FF8, $3FF6, $7FFC, $FE8, $7DF, $FC9, $FD7, $FDC, $1FDC, $1FDF,
        $1FED, $1FF5, $3FF9, $3FFB, $7FFD, $7FFE, $1FE7, $FCC, $FD6, $FDF,
        $1FDE, $1FDA, $1FE5, $1FF2, $3FFA, $3FF7, $3FFC, $3FFD, $7FFF
      );
    10:
      ref := TArray<Cardinal>.Create(
        $22, $8, $1D, $26, $5F, $D3, $1CF, $3D0, $3D7, $3ED,
        $7F0, $7F6, $FFD, $7, $0, $1, $9, $20, $54, $60,
        $D5, $DC, $1D4, $3CD, $3DE, $7E7, $1C, $2, $6, $C,
        $1E, $28, $5B, $CD, $D9, $1CE, $1DC, $3D9, $3F1, $25,
        $B, $A, $D, $24, $57, $61, $CC, $DD, $1CC, $1DE,
        $3D3, $3E7, $5D, $21, $1F, $23, $27, $59, $64, $D8,
        $DF, $1D2, $1E2, $3DD, $3EE, $D1, $55, $29, $56, $58,
        $62, $CE, $E0, $E2, $1DA, $3D4, $3E3, $7EB, $1C9, $5E,
        $5A, $5C, $63, $CA, $DA, $1C7, $1CA, $1E0, $3DB, $3E8,
        $7EC, $1E3, $D2, $CB, $D0, $D7, $DB, $1C6, $1D5, $1D8,
        $3CA, $3DA, $7EA, $7F1, $1E1, $D4, $CF, $D6, $DE, $E1,
        $1D0, $1D6, $3D1, $3D5, $3F2, $7EE, $7FB, $3E9, $1CD, $1C8,
        $1CB, $1D1, $1D7, $1DF, $3CF, $3E0, $3EF, $7E6, $7F8, $FFA,
        $3EB, $1DD, $1D3, $1D9, $1DB, $3D2, $3CC, $3DC, $3EA, $7ED,
        $7F3, $7F9, $FF9, $7F2, $3CE, $1E4, $3CB, $3D8, $3D6, $3E2,
        $3E5, $7E8, $7F4, $7F5, $7F7, $FFB, $7FA, $3EC, $3DF, $3E1,
        $3E4, $3E6, $3F0, $7E9, $7EF, $FF8, $FFE, $FFC, $FFF
      );
    11:
      ref := TArray<Cardinal>.Create(
        $0, $6, $19, $3D, $9C, $C6, $1A7, $390, $3C2, $3DF,
        $7E6, $7F3, $FFB, $7EC, $FFA, $FFE, $38E, $5, $1, $8,
        $14, $37, $42, $92, $AF, $191, $1A5, $1B5, $39E, $3C0,
        $3A2, $3CD, $7D6, $AE, $17, $7, $9, $18, $39, $40,
        $8E, $A3, $B8, $199, $1AC, $1C1, $3B1, $396, $3BE, $3CA,
        $9D, $3C, $15, $16, $1A, $3B, $44, $91, $A5, $BE,
        $196, $1AE, $1B9, $3A1, $391, $3A5, $3D5, $94, $9A, $36,
        $38, $3A, $41, $8C, $9B, $B0, $C3, $19E, $1AB, $1BC,
        $39F, $38F, $3A9, $3CF, $93, $BF, $3E, $3F, $43, $45,
        $9E, $A7, $B9, $194, $1A2, $1BA, $1C3, $3A6, $3A7, $3BB,
        $3D4, $9F, $1A0, $8F, $8D, $90, $98, $A6, $B6, $C4,
        $19F, $1AF, $1BF, $399, $3BF, $3B4, $3C9, $3E7, $A8, $1B6,
        $AB, $A4, $AA, $B2, $C2, $C5, $198, $1A4, $1B8, $38C,
        $3A4, $3C4, $3C6, $3DD, $3E8, $AD, $3AF, $192, $BD, $BC,
        $18E, $197, $19A, $1A3, $1B1, $38D, $398, $3B7, $3D3, $3D1,
        $3DB, $7DD, $B4, $3DE, $1A9, $19B, $19C, $1A1, $1AA, $1AD,
        $1B3, $38B, $3B2, $3B8, $3CE, $3E1, $3E0, $7D2, $7E5, $B7,
        $7E3, $1BB, $1A8, $1A6, $1B0, $1B2, $1B7, $39B, $39A, $3BA,
        $3B5, $3D6, $7D7, $3E4, $7D8, $7EA, $BA, $7E8, $3A0, $1BD,
        $1B4, $38A, $1C4, $392, $3AA, $3B0, $3BC, $3D7, $7D4, $7DC,
        $7DB, $7D5, $7F0, $C1, $7FB, $3C8, $3A3, $395, $39D, $3AC,
        $3AE, $3C5, $3D8, $3E2, $3E6, $7E4, $7E7, $7E0, $7E9, $7F7,
        $190, $7F2, $393, $1BE, $1C0, $394, $397, $3AD, $3C3, $3C1,
        $3D2, $7DA, $7D9, $7DF, $7EB, $7F4, $7FA, $195, $7F8, $3BD,
        $39C, $3AB, $3A8, $3B3, $3B9, $3D0, $3E3, $3E5, $7E2, $7DE,
        $7ED, $7F1, $7F9, $7FC, $193, $FFD, $3DC, $3B6, $3C7, $3CC,
        $3CB, $3D9, $3DA, $7D3, $7E1, $7EE, $7EF, $7F5, $7F6, $FFC,
        $FFF, $19D, $1C2, $B5, $A1, $96, $97, $95, $99, $A0,
        $A2, $AC, $A9, $B1, $B3, $BB, $C0, $18F, $4
      );
  else
    Exit;
  end;
  for i := 0 to High(ref) do
    if i <= High(ACodes) then
      ACodes[i] := ref[i];
end;

procedure AacFlatBits(var A: TAacByteArr; ACount: Integer);
var
  i, L: Integer;
begin
  { flat prefix code: valid tree, deliberately wrong values, Kraft = count/2^L
    so HuffBooksSelfCheck trips if a book's real data is ever missing/short }
  L := 1;
  while (1 shl L) < ACount do Inc(L);
  SetLength(A, ACount);
  for i := 0 to ACount - 1 do A[i] := L;
  if ACount >= 2 then
  begin
    A[0] := L + 1;
    A[1] := L + 1;
  end;
end;

procedure InitAacHuffData;
var
  b, i, cnt, L: Integer;
  bits: TAacByteArr;
  acc: UInt64;
begin
  for b := 0 to 11 do
  begin
    cnt := AAC_HCB_META[b, 4];
    AacHCB[b].Num    := b;
    AacHCB[b].Dim    := AAC_HCB_META[b, 0];
    AacHCB[b].ModVal := AAC_HCB_META[b, 1];
    AacHCB[b].LavMax := AAC_HCB_META[b, 2];
    AacHCB[b].Signed := AAC_HCB_META[b, 3] <> 0;

    bits := nil;
    AacGetBookBits(b, bits);
    if Length(bits) <> cnt then
      AacFlatBits(bits, cnt);

    SetLength(AacHCB[b].Lens, cnt);
    for i := 0 to cnt - 1 do AacHCB[b].Lens[i] := bits[i];

    SetLength(AacHCB[b].Codes, cnt);
    acc := 0;
    for i := 0 to cnt - 1 do
    begin
      L := AacHCB[b].Lens[i];
      if L <= 0 then
      begin
        AacHCB[b].Codes[i] := 0;
        Continue;
      end;
      AacHCB[b].Codes[i] := Cardinal(acc shr (32 - L));
      acc := acc + (UInt64(1) shl (32 - L));
    end;

    AacApplyBookCodes(b, AacHCB[b].Codes);
  end;
end;
