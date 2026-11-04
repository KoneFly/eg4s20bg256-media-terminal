// ============================================================================
// pcb_roms.vh —— 三张常量 ROM（自动生成：node sim/gen_roms.cjs，勿手改）
// 生成日期: 2026-09-27 ｜ 维护者: task_045 执行方
// 来源: pcb_model.js PCB_PAL（色标 spec/M6_PCB_SKETCH.md §1）· pcb_layout.js total
// 用法: 在 pcb_pixel_renderer 模块体内 `include 本文件（函数在模块作用域内）
// ============================================================================

// 径向调色板基色 64×24：idx = 半径档 0..63，{R,G,B} 各 8bit
function [23:0] pcb_pal_rom;
  input [5:0] idx;
  begin
    case (idx)
      6'd0: pcb_pal_rom = 24'h40ECD6; // (64,236,214)
      6'd1: pcb_pal_rom = 24'h41E9D9; // (65,233,217)
      6'd2: pcb_pal_rom = 24'h42E5DB; // (66,229,219)
      6'd3: pcb_pal_rom = 24'h43E2DE; // (67,226,222)
      6'd4: pcb_pal_rom = 24'h44DEE1; // (68,222,225)
      6'd5: pcb_pal_rom = 24'h45DBE4; // (69,219,228)
      6'd6: pcb_pal_rom = 24'h46D7E6; // (70,215,230)
      6'd7: pcb_pal_rom = 24'h47D4E9; // (71,212,233)
      6'd8: pcb_pal_rom = 24'h49D0EC; // (73,208,236)
      6'd9: pcb_pal_rom = 24'h4ACDEF; // (74,205,239)
      6'd10: pcb_pal_rom = 24'h4BC9F1; // (75,201,241)
      6'd11: pcb_pal_rom = 24'h4CC6F4; // (76,198,244)
      6'd12: pcb_pal_rom = 24'h4DC2F7; // (77,194,247)
      6'd13: pcb_pal_rom = 24'h4EBFFA; // (78,191,250)
      6'd14: pcb_pal_rom = 24'h4FBBFC; // (79,187,252)
      6'd15: pcb_pal_rom = 24'h50B8FF; // (80,184,255)
      6'd16: pcb_pal_rom = 24'h55B4FF; // (85,180,255)
      6'd17: pcb_pal_rom = 24'h59B0FF; // (89,176,255)
      6'd18: pcb_pal_rom = 24'h5EACFF; // (94,172,255)
      6'd19: pcb_pal_rom = 24'h63A7FF; // (99,167,255)
      6'd20: pcb_pal_rom = 24'h67A3FF; // (103,163,255)
      6'd21: pcb_pal_rom = 24'h6C9FFF; // (108,159,255)
      6'd22: pcb_pal_rom = 24'h719BFF; // (113,155,255)
      6'd23: pcb_pal_rom = 24'h7597FF; // (117,151,255)
      6'd24: pcb_pal_rom = 24'h7A93FF; // (122,147,255)
      6'd25: pcb_pal_rom = 24'h7F8FFF; // (127,143,255)
      6'd26: pcb_pal_rom = 24'h838BFF; // (131,139,255)
      6'd27: pcb_pal_rom = 24'h8886FF; // (136,134,255)
      6'd28: pcb_pal_rom = 24'h8D82FF; // (141,130,255)
      6'd29: pcb_pal_rom = 24'h917EFF; // (145,126,255)
      6'd30: pcb_pal_rom = 24'h967AFF; // (150,122,255)
      6'd31: pcb_pal_rom = 24'h9C78FC; // (156,120,252)
      6'd32: pcb_pal_rom = 24'hA276F8; // (162,118,248)
      6'd33: pcb_pal_rom = 24'hA975F5; // (169,117,245)
      6'd34: pcb_pal_rom = 24'hAF73F1; // (175,115,241)
      6'd35: pcb_pal_rom = 24'hB571EE; // (181,113,238)
      6'd36: pcb_pal_rom = 24'hBB6FEA; // (187,111,234)
      6'd37: pcb_pal_rom = 24'hC16EE7; // (193,110,231)
      6'd38: pcb_pal_rom = 24'hC76CE3; // (199,108,227)
      6'd39: pcb_pal_rom = 24'hCE6AE0; // (206,106,224)
      6'd40: pcb_pal_rom = 24'hD468DC; // (212,104,220)
      6'd41: pcb_pal_rom = 24'hDA67D9; // (218,103,217)
      6'd42: pcb_pal_rom = 24'hE065D5; // (224,101,213)
      6'd43: pcb_pal_rom = 24'hE663D2; // (230,99,210)
      6'd44: pcb_pal_rom = 24'hEC61CE; // (236,97,206)
      6'd45: pcb_pal_rom = 24'hF360CB; // (243,96,203)
      6'd46: pcb_pal_rom = 24'hF95EC7; // (249,94,199)
      6'd47: pcb_pal_rom = 24'hFF5CC4; // (255,92,196)
      6'd48: pcb_pal_rom = 24'hFF63BA; // (255,99,186)
      6'd49: pcb_pal_rom = 24'hFF6AAF; // (255,106,175)
      6'd50: pcb_pal_rom = 24'hFF71A5; // (255,113,165)
      6'd51: pcb_pal_rom = 24'hFF789B; // (255,120,155)
      6'd52: pcb_pal_rom = 24'hFF7F90; // (255,127,144)
      6'd53: pcb_pal_rom = 24'hFF8686; // (255,134,134)
      6'd54: pcb_pal_rom = 24'hFF8D7C; // (255,141,124)
      6'd55: pcb_pal_rom = 24'hFF9471; // (255,148,113)
      6'd56: pcb_pal_rom = 24'hFF9B67; // (255,155,103)
      6'd57: pcb_pal_rom = 24'hFFA25D; // (255,162,93)
      6'd58: pcb_pal_rom = 24'hFFA952; // (255,169,82)
      6'd59: pcb_pal_rom = 24'hFFB048; // (255,176,72)
      6'd60: pcb_pal_rom = 24'hFFB048; // (255,176,72)
      6'd61: pcb_pal_rom = 24'hFFB048; // (255,176,72)
      6'd62: pcb_pal_rom = 24'hFFB048; // (255,176,72)
      6'd63: pcb_pal_rom = 24'hFFB048; // (255,176,72)
      default: pcb_pal_rom = 24'h000000;
    endcase
  end
endfunction

// 底部柱形图通道→调色索引 128×7：min(63, floor(col*59/127))，JS 权威实现为 floor
function [6:0] pcb_chidx_rom;
  input [6:0] col;
  begin
    case (col)
      7'd000: pcb_chidx_rom = 7'd0; 7'd001: pcb_chidx_rom = 7'd0; 7'd002: pcb_chidx_rom = 7'd0; 7'd003: pcb_chidx_rom = 7'd1; 7'd004: pcb_chidx_rom = 7'd1; 7'd005: pcb_chidx_rom = 7'd2; 7'd006: pcb_chidx_rom = 7'd2; 7'd007: pcb_chidx_rom = 7'd3;
      7'd008: pcb_chidx_rom = 7'd3; 7'd009: pcb_chidx_rom = 7'd4; 7'd010: pcb_chidx_rom = 7'd4; 7'd011: pcb_chidx_rom = 7'd5; 7'd012: pcb_chidx_rom = 7'd5; 7'd013: pcb_chidx_rom = 7'd6; 7'd014: pcb_chidx_rom = 7'd6; 7'd015: pcb_chidx_rom = 7'd6;
      7'd016: pcb_chidx_rom = 7'd7; 7'd017: pcb_chidx_rom = 7'd7; 7'd018: pcb_chidx_rom = 7'd8; 7'd019: pcb_chidx_rom = 7'd8; 7'd020: pcb_chidx_rom = 7'd9; 7'd021: pcb_chidx_rom = 7'd9; 7'd022: pcb_chidx_rom = 7'd10; 7'd023: pcb_chidx_rom = 7'd10;
      7'd024: pcb_chidx_rom = 7'd11; 7'd025: pcb_chidx_rom = 7'd11; 7'd026: pcb_chidx_rom = 7'd12; 7'd027: pcb_chidx_rom = 7'd12; 7'd028: pcb_chidx_rom = 7'd13; 7'd029: pcb_chidx_rom = 7'd13; 7'd030: pcb_chidx_rom = 7'd13; 7'd031: pcb_chidx_rom = 7'd14;
      7'd032: pcb_chidx_rom = 7'd14; 7'd033: pcb_chidx_rom = 7'd15; 7'd034: pcb_chidx_rom = 7'd15; 7'd035: pcb_chidx_rom = 7'd16; 7'd036: pcb_chidx_rom = 7'd16; 7'd037: pcb_chidx_rom = 7'd17; 7'd038: pcb_chidx_rom = 7'd17; 7'd039: pcb_chidx_rom = 7'd18;
      7'd040: pcb_chidx_rom = 7'd18; 7'd041: pcb_chidx_rom = 7'd19; 7'd042: pcb_chidx_rom = 7'd19; 7'd043: pcb_chidx_rom = 7'd19; 7'd044: pcb_chidx_rom = 7'd20; 7'd045: pcb_chidx_rom = 7'd20; 7'd046: pcb_chidx_rom = 7'd21; 7'd047: pcb_chidx_rom = 7'd21;
      7'd048: pcb_chidx_rom = 7'd22; 7'd049: pcb_chidx_rom = 7'd22; 7'd050: pcb_chidx_rom = 7'd23; 7'd051: pcb_chidx_rom = 7'd23; 7'd052: pcb_chidx_rom = 7'd24; 7'd053: pcb_chidx_rom = 7'd24; 7'd054: pcb_chidx_rom = 7'd25; 7'd055: pcb_chidx_rom = 7'd25;
      7'd056: pcb_chidx_rom = 7'd26; 7'd057: pcb_chidx_rom = 7'd26; 7'd058: pcb_chidx_rom = 7'd26; 7'd059: pcb_chidx_rom = 7'd27; 7'd060: pcb_chidx_rom = 7'd27; 7'd061: pcb_chidx_rom = 7'd28; 7'd062: pcb_chidx_rom = 7'd28; 7'd063: pcb_chidx_rom = 7'd29;
      7'd064: pcb_chidx_rom = 7'd29; 7'd065: pcb_chidx_rom = 7'd30; 7'd066: pcb_chidx_rom = 7'd30; 7'd067: pcb_chidx_rom = 7'd31; 7'd068: pcb_chidx_rom = 7'd31; 7'd069: pcb_chidx_rom = 7'd32; 7'd070: pcb_chidx_rom = 7'd32; 7'd071: pcb_chidx_rom = 7'd32;
      7'd072: pcb_chidx_rom = 7'd33; 7'd073: pcb_chidx_rom = 7'd33; 7'd074: pcb_chidx_rom = 7'd34; 7'd075: pcb_chidx_rom = 7'd34; 7'd076: pcb_chidx_rom = 7'd35; 7'd077: pcb_chidx_rom = 7'd35; 7'd078: pcb_chidx_rom = 7'd36; 7'd079: pcb_chidx_rom = 7'd36;
      7'd080: pcb_chidx_rom = 7'd37; 7'd081: pcb_chidx_rom = 7'd37; 7'd082: pcb_chidx_rom = 7'd38; 7'd083: pcb_chidx_rom = 7'd38; 7'd084: pcb_chidx_rom = 7'd39; 7'd085: pcb_chidx_rom = 7'd39; 7'd086: pcb_chidx_rom = 7'd39; 7'd087: pcb_chidx_rom = 7'd40;
      7'd088: pcb_chidx_rom = 7'd40; 7'd089: pcb_chidx_rom = 7'd41; 7'd090: pcb_chidx_rom = 7'd41; 7'd091: pcb_chidx_rom = 7'd42; 7'd092: pcb_chidx_rom = 7'd42; 7'd093: pcb_chidx_rom = 7'd43; 7'd094: pcb_chidx_rom = 7'd43; 7'd095: pcb_chidx_rom = 7'd44;
      7'd096: pcb_chidx_rom = 7'd44; 7'd097: pcb_chidx_rom = 7'd45; 7'd098: pcb_chidx_rom = 7'd45; 7'd099: pcb_chidx_rom = 7'd45; 7'd100: pcb_chidx_rom = 7'd46; 7'd101: pcb_chidx_rom = 7'd46; 7'd102: pcb_chidx_rom = 7'd47; 7'd103: pcb_chidx_rom = 7'd47;
      7'd104: pcb_chidx_rom = 7'd48; 7'd105: pcb_chidx_rom = 7'd48; 7'd106: pcb_chidx_rom = 7'd49; 7'd107: pcb_chidx_rom = 7'd49; 7'd108: pcb_chidx_rom = 7'd50; 7'd109: pcb_chidx_rom = 7'd50; 7'd110: pcb_chidx_rom = 7'd51; 7'd111: pcb_chidx_rom = 7'd51;
      7'd112: pcb_chidx_rom = 7'd52; 7'd113: pcb_chidx_rom = 7'd52; 7'd114: pcb_chidx_rom = 7'd52; 7'd115: pcb_chidx_rom = 7'd53; 7'd116: pcb_chidx_rom = 7'd53; 7'd117: pcb_chidx_rom = 7'd54; 7'd118: pcb_chidx_rom = 7'd54; 7'd119: pcb_chidx_rom = 7'd55;
      7'd120: pcb_chidx_rom = 7'd55; 7'd121: pcb_chidx_rom = 7'd56; 7'd122: pcb_chidx_rom = 7'd56; 7'd123: pcb_chidx_rom = 7'd57; 7'd124: pcb_chidx_rom = 7'd57; 7'd125: pcb_chidx_rom = 7'd58; 7'd126: pcb_chidx_rom = 7'd58; 7'd127: pcb_chidx_rom = 7'd59;
      default: pcb_chidx_rom = 7'd0;
    endcase
  end
endfunction

// 走线满长 total 128×7（版图常量；class2/3 尖端判据 k==len && len<total 用）
// ★ 偏差登记：INTERFACE_SPEC 禁止另存 total，但其化简与黄金实证不符 —— 见 run_report.md
function [6:0] pcb_total_rom;
  input [6:0] id;
  begin
    case (id)
      7'd000: pcb_total_rom = 7'd64; 7'd001: pcb_total_rom = 7'd64; 7'd002: pcb_total_rom = 7'd64; 7'd003: pcb_total_rom = 7'd64; 7'd004: pcb_total_rom = 7'd64; 7'd005: pcb_total_rom = 7'd64; 7'd006: pcb_total_rom = 7'd64; 7'd007: pcb_total_rom = 7'd64;
      7'd008: pcb_total_rom = 7'd64; 7'd009: pcb_total_rom = 7'd64; 7'd010: pcb_total_rom = 7'd110; 7'd011: pcb_total_rom = 7'd34; 7'd012: pcb_total_rom = 7'd62; 7'd013: pcb_total_rom = 7'd12; 7'd014: pcb_total_rom = 7'd48; 7'd015: pcb_total_rom = 7'd94;
      7'd016: pcb_total_rom = 7'd63; 7'd017: pcb_total_rom = 7'd75; 7'd018: pcb_total_rom = 7'd64; 7'd019: pcb_total_rom = 7'd68; 7'd020: pcb_total_rom = 7'd104; 7'd021: pcb_total_rom = 7'd42; 7'd022: pcb_total_rom = 7'd42; 7'd023: pcb_total_rom = 7'd42;
      7'd024: pcb_total_rom = 7'd42; 7'd025: pcb_total_rom = 7'd19; 7'd026: pcb_total_rom = 7'd16; 7'd027: pcb_total_rom = 7'd28; 7'd028: pcb_total_rom = 7'd8; 7'd029: pcb_total_rom = 7'd14; 7'd030: pcb_total_rom = 7'd22; 7'd031: pcb_total_rom = 7'd44;
      7'd032: pcb_total_rom = 7'd60; 7'd033: pcb_total_rom = 7'd102; 7'd034: pcb_total_rom = 7'd100; 7'd035: pcb_total_rom = 7'd97; 7'd036: pcb_total_rom = 7'd95; 7'd037: pcb_total_rom = 7'd92; 7'd038: pcb_total_rom = 7'd89; 7'd039: pcb_total_rom = 7'd7;
      7'd040: pcb_total_rom = 7'd110; 7'd041: pcb_total_rom = 7'd110; 7'd042: pcb_total_rom = 7'd110; 7'd043: pcb_total_rom = 7'd109; 7'd044: pcb_total_rom = 7'd70; 7'd045: pcb_total_rom = 7'd78; 7'd046: pcb_total_rom = 7'd70; 7'd047: pcb_total_rom = 7'd78;
      7'd048: pcb_total_rom = 7'd70; 7'd049: pcb_total_rom = 7'd78; 7'd050: pcb_total_rom = 7'd70; 7'd051: pcb_total_rom = 7'd12; 7'd052: pcb_total_rom = 7'd36; 7'd053: pcb_total_rom = 7'd90; 7'd054: pcb_total_rom = 7'd36; 7'd055: pcb_total_rom = 7'd36;
      7'd056: pcb_total_rom = 7'd94; 7'd057: pcb_total_rom = 7'd97; 7'd058: pcb_total_rom = 7'd99; 7'd059: pcb_total_rom = 7'd101; 7'd060: pcb_total_rom = 7'd103; 7'd061: pcb_total_rom = 7'd9; 7'd062: pcb_total_rom = 7'd26; 7'd063: pcb_total_rom = 7'd70;
      7'd064: pcb_total_rom = 7'd104; 7'd065: pcb_total_rom = 7'd103; 7'd066: pcb_total_rom = 7'd101; 7'd067: pcb_total_rom = 7'd99; 7'd068: pcb_total_rom = 7'd97; 7'd069: pcb_total_rom = 7'd94; 7'd070: pcb_total_rom = 7'd0; 7'd071: pcb_total_rom = 7'd0;
      7'd072: pcb_total_rom = 7'd0; 7'd073: pcb_total_rom = 7'd0; 7'd074: pcb_total_rom = 7'd0; 7'd075: pcb_total_rom = 7'd0; 7'd076: pcb_total_rom = 7'd0; 7'd077: pcb_total_rom = 7'd0; 7'd078: pcb_total_rom = 7'd0; 7'd079: pcb_total_rom = 7'd0;
      7'd080: pcb_total_rom = 7'd0; 7'd081: pcb_total_rom = 7'd0; 7'd082: pcb_total_rom = 7'd0; 7'd083: pcb_total_rom = 7'd0; 7'd084: pcb_total_rom = 7'd0; 7'd085: pcb_total_rom = 7'd0; 7'd086: pcb_total_rom = 7'd0; 7'd087: pcb_total_rom = 7'd0;
      7'd088: pcb_total_rom = 7'd0; 7'd089: pcb_total_rom = 7'd0; 7'd090: pcb_total_rom = 7'd0; 7'd091: pcb_total_rom = 7'd0; 7'd092: pcb_total_rom = 7'd0; 7'd093: pcb_total_rom = 7'd0; 7'd094: pcb_total_rom = 7'd0; 7'd095: pcb_total_rom = 7'd0;
      7'd096: pcb_total_rom = 7'd0; 7'd097: pcb_total_rom = 7'd0; 7'd098: pcb_total_rom = 7'd0; 7'd099: pcb_total_rom = 7'd0; 7'd100: pcb_total_rom = 7'd0; 7'd101: pcb_total_rom = 7'd0; 7'd102: pcb_total_rom = 7'd0; 7'd103: pcb_total_rom = 7'd0;
      7'd104: pcb_total_rom = 7'd0; 7'd105: pcb_total_rom = 7'd0; 7'd106: pcb_total_rom = 7'd0; 7'd107: pcb_total_rom = 7'd0; 7'd108: pcb_total_rom = 7'd0; 7'd109: pcb_total_rom = 7'd0; 7'd110: pcb_total_rom = 7'd0; 7'd111: pcb_total_rom = 7'd0;
      7'd112: pcb_total_rom = 7'd0; 7'd113: pcb_total_rom = 7'd0; 7'd114: pcb_total_rom = 7'd0; 7'd115: pcb_total_rom = 7'd0; 7'd116: pcb_total_rom = 7'd0; 7'd117: pcb_total_rom = 7'd0; 7'd118: pcb_total_rom = 7'd0; 7'd119: pcb_total_rom = 7'd0;
      7'd120: pcb_total_rom = 7'd0; 7'd121: pcb_total_rom = 7'd0; 7'd122: pcb_total_rom = 7'd0; 7'd123: pcb_total_rom = 7'd0; 7'd124: pcb_total_rom = 7'd0; 7'd125: pcb_total_rom = 7'd0; 7'd126: pcb_total_rom = 7'd0; 7'd127: pcb_total_rom = 7'd0;
      default: pcb_total_rom = 7'd0;
    endcase
  end
endfunction
