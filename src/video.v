`default_nettype none

// Implementation of the Sega Master System games console for the Ulx3s FPGA board.
// It uses buttons for joypad 1.
// Games are via the ESP32 using an On-screen Display (OSD).
// Has HDMI and optional VGA output.
// Implemented entirely in Verilog.
module video (
  input         clk,
  input         reset,
  output [7:0]  vga_r,
  output [7:0]  vga_b,
  output [7:0]  vga_g,
  output        vga_hs,
  output        vga_vs,
  output        vga_de,
  input  [7:0]  vga_din,
  output [7:0]  vga_dout,
  input [13:0]  vga_addr,
  input         vga_wr,
  input         vga_rd,
  input  [2:0]  mode,
  input         cpu_clk,
  input [13:0]  font_addr,
  input [13:0]  name_table_addr,
  input [13:0]  sprite_attr_addr,
  input [13:0]  sprite_pattern_table_addr,
  input [13:0]  color_table_addr,
  input         cram_selected,
  input         video_on,
  input [3:0]   text_color,
  input [3:0]   back_color,
  input         sprite_large,
  input         sprite_enlarged,
  input         vert_retrace_int,
  output        n_int,
  output        sprite_collision,
  output        too_many_sprites,
  output        interrupt_flag,
  output [4:0]  spritex,
  input [7:0]   x_scroll,
  input [7:0]   y_scroll,
  input         disable_vert,
  input         disable_horiz,
  input         lines224,
  input         lines240,
  output [7:0]  v_counter,
  output [7:0]  h_counter,
  output reg [15:0] diag
);

  // VGA output parameters for 60hz 640x480
  parameter HA = 640;
  parameter HS  = 96;
  parameter HFP = 16;
  parameter HBP = 48;
  parameter HT  = HA + HS + HFP + HBP;
  parameter HB = 64;
  parameter HB2 = HB/2;
  parameter HBadj = 12; // Border adjustment

  parameter VA = 480;
  parameter VS  = 2;
  parameter VFP = 11;
  parameter VBP = 31;
  parameter VT  = VA + VS + VFP + VBP;
  parameter VB = 48;
  parameter VB2 = VB/2;

  localparam NUM_SPRITES = 32;
  localparam NUM_SPRITES2 = NUM_SPRITES * 2;
  localparam NUM_ACTIVE_SPRITES = 8;
  localparam NUM_ACTIVE_LEGACY_SPRITES = 4;
  localparam NUM_ACTIVE_SPRITES2 = NUM_ACTIVE_SPRITES * 2;
  localparam NUM_ACTIVE_SPRITES8 = NUM_ACTIVE_SPRITES * 8;

  localparam SPRITE_SCAN_END = HA + NUM_SPRITES2;
  localparam SPRITE_ATTR_SCAN_END = SPRITE_SCAN_END + NUM_ACTIVE_SPRITES8;
  localparam SPRITE_PATTERN_SCAN_END = SPRITE_ATTR_SCAN_END + NUM_ACTIVE_SPRITES2;
  localparam SPRITE_PATTERN2_SCAN_END = SPRITE_PATTERN_SCAN_END + NUM_ACTIVE_SPRITES2;

  // MSX color palette
  localparam transparent  = 24'h000000;
  localparam black        = 24'h010101;
  localparam medium_green = 24'h3eb849;
  localparam light_green  = 24'h74d07d;
  localparam dark_blue    = 24'h5955e0;
  localparam light_blue   = 24'h8076f1;
  localparam dark_red     = 24'h993e31;
  localparam cyan         = 24'h65dbef;
  localparam medium_red   = 24'hdb6559;
  localparam light_red    = 24'hff897d;
  localparam dark_yellow  = 24'hccc35e;
  localparam light_yellow = 24'hded087;
  localparam dark_green   = 24'h3aa241;
  localparam magenta      = 24'hb766b5;
  localparam gray         = 24'h777777;
  localparam white        = 24'hffffff;

  // Palettes
  reg [23:0] colors1 [0:15];
  reg [23:0] colors2 [0:15];

  initial begin
    colors1[0]  = transparent;
    colors1[1]  = black;
    colors1[2]  = medium_green;
    colors1[3]  = light_green;
    colors1[4]  = dark_blue;
    colors1[5]  = light_blue;
    colors1[6]  = dark_red;
    colors1[7]  = cyan;
    colors1[8]  = medium_red;
    colors1[9]  = light_red;
    colors1[10] = dark_yellow;
    colors1[11] = light_yellow;
    colors1[12] = dark_green;
    colors1[13] = magenta;
    colors1[14] = gray;
    colors1[15] = white;

    colors2[0]  = transparent;
    colors2[1]  = black;
    colors2[2]  = medium_green;
    colors2[3]  = light_green;
    colors2[4]  = dark_blue;
    colors2[5]  = light_blue;
    colors2[6]  = dark_red;
    colors2[7]  = cyan;
    colors2[8]  = medium_red;
    colors2[9]  = light_red;
    colors2[10] = dark_yellow;
    colors2[11] = light_yellow;
    colors2[12] = dark_green;
    colors2[13] = magenta;
    colors2[14] = gray;
    colors2[15] = white;
  end

  // Data for graphics and sprites
  reg [7:0] screen_color;
  reg [7:0] screen_color_next;

  // Legacy modes only support 4 sprites, mode 4 supports 8
  reg [7:0] sprite_y [0:NUM_ACTIVE_SPRITES-1];
  reg [7:0] sprite_x [0:NUM_ACTIVE_SPRITES-1];
  reg [3:0] sprite_color [0:NUM_ACTIVE_SPRITES-1];
  reg [7:0] sprite_pattern [0:NUM_ACTIVE_SPRITES-1];
  reg [NUM_ACTIVE_SPRITES-1:0] sprite_ec;
  reg [4:0] sprite_num [0:NUM_ACTIVE_SPRITES-1];
  reg [7:0] sprite_line [0:NUM_ACTIVE_SPRITES-1];

  // Fonts are used differently for mode 4, as there are 4 bit planes
  reg [7:0] sprite_font [0:NUM_ACTIVE_SPRITES-1];
  reg [7:0] sprite_font1 [0:NUM_ACTIVE_SPRITES-1];
  reg [7:0] sprite_font2 [0:NUM_ACTIVE_SPRITES-1];
  reg [7:0] sprite_font3 [0:NUM_ACTIVE_SPRITES-1];

  reg [9:0] hc = 0;
  reg [9:0] vc = 0;

  reg INT = 0;
  reg [5:0] intCnt = 1;

  reg [7:0] r_char;
  reg [7:0] font_line;
  
  reg [7:0] sprite_pixel;
  reg       sprites_done;
  reg [3:0] num_sprites;

  wire [7:0] sprite_sy1 [0:NUM_ACTIVE_SPRITES+1]; // Start y pos + 1
  wire [7:0] sprite_ey1 [0:NUM_ACTIVE_SPRITES+1]; // End y pos + 1
  wire [8:0] sprite_sx  [0:NUM_ACTIVE_SPRITES-1]; // Start x pos 0 - 287
  wire [8:0] sprite_ex  [0:NUM_ACTIVE_SPRITES+1]; // End y pos of first 8 pixels 
  wire [8:0] sprite_exl [0:NUM_ACTIVE_SPRITES+1]; // End y pos

  // Sprite collision count
  wire [3:0] sprite_count = 
             sprite_pixel[7] + sprite_pixel[6] + 
             sprite_pixel[5] + sprite_pixel[4] + 
             sprite_pixel[3] + sprite_pixel[2] + 
             sprite_pixel[1] + sprite_pixel[0];

  // Sprite collision status data
  assign sprite_collision  = (sprite_count > 1);
  assign too_many_sprites = (num_sprites > 8);
  reg [4:0] spritex;

  // Set CPU interrupt flag
  assign n_int = !INT;
  // Status interrupt flag
  assign interrupt_flag = (hc == VA);

  assign vga_hs = !(hc >= HA + HFP && hc < HA + HFP + HS);
  assign vga_vs = !(vc >= VA + VFP && vc < VA + VFP + VS);
  assign vga_de = !(hc >= HA || vc >= VA);

  // Set x and y to screen pixel coordinates. x not valid in text mode
  wire [7:0] x = hc[9:1] - HB2;
  wire [7:0] y = vc[9:1] - VB2;

  assign v_counter = y;
  assign h_counter = x;

  // Set the x position as a character and pixel offset. Valid in all modes.
  reg [4:0] x_char;
  reg [2:0] x_pix;

  wire [3:0] char_width = (mode == 0 ? 6 : 8);
  wire [4:0] next_char = x_char + 1;
  wire [4:0] next_scroll = x_pix < 16 && disable_horiz ? next_char : next_char - x_scroll[7:3];

  // Calculate the border
  wire [9:0] hb_adj = (mode == 0 ? HBadj : 0);
  wire hBorder = (hc < (HB + hb_adj) || hc >= HA - HB - hb_adj);
  wire vBorder = (vc < VB || vc >= VA - VB);
  wire border = hBorder || vBorder;

  // Sprite data for modes 2 and 3

  // Calculate pixel positions for 4 active sprites
  wire [2:0] sprite_col [0:NUM_ACTIVE_SPRITES-1];
  wire [3:0] sprite_row [0:NUM_ACTIVE_SPRITES-1];

  // Sprite horizontal positions start at -32, and have range 0 - 287
  wire [7:0] x1 = x + 1;
  wire [8:0] x33 = (hc - HB + 66) >> 1; // x+1, starting from -32
  wire [8:0] x34 = (hc - HB + 68) >> 1; // x+2, starting from -32

  wire [7:0] y32 = y + 32;
  // Start and end sprite position during sprite scan, starting at x-32
  wire [7:0] sprite_sy = vid_out + 32;
  wire [7:0] sprite_ey = vid_out + 32  + ((8 << sprite_enlarged) << sprite_large);

  // Mode 4 data
  reg [7:0] first_index_byte;
  reg [7:0] second_index_byte;
  reg [7:0] bit_plane [0:3];
  reg [7:0] bit_plane_next [0:3];

  reg [7:0] r_y_scroll;

  wire [2:0] x_scroll_pix = x_pix < 16 && disable_horiz ? x_pix : x_pix - x_scroll[2:0];

  wire [7:0] depth = (line240 ? 240 : line224 : 224 : 192);
  wire [7:0] y_limit = (lines240 | lines224) ? 255 : 223;
  wire [8:0] ys = y + r_y_scroll;
  wire [7:0] ysa = ys > y_limit ? ys - 224 : ys;
  wire [4:0] y_char_scroll = x_char >= 24 && disable_vert ? y[7:3] : ysa[7:3];

  wire [2:0] y_scroll_pix = x_char >= 24 && disable_vert ? y[2:0] : y[2:0] + y_scroll[2:0];
  
  reg h_flip, palette, priority;

  wire [3:0] sprite_color4 [0:NUM_ACTIVE_SPRITES-1];
  wire [7:0] xa = x - 6;
  wire [2:0] sind = sprite_enlarged ? ~xa[3:1] : ~x[2:0];
  wire [7:0] ya = y - 6;
  wire [2:0] ysp = sprite_enlarged ? ya[3:1] : y[2:0];

  // Generate sprite arrays
  generate
    genvar j;
    for(j=0;j<NUM_ACTIVE_SPRITES;j=j+1) begin
      assign sprite_col[j] = ((x1 - sprite_x[j]) >> sprite_enlarged);
      assign sprite_row[j] = ((y - sprite_y[j]) >> sprite_enlarged);
      assign sprite_sx[j]  = sprite_x[j] + (sprite_ec[j] ? 0 : 32);
      assign sprite_ex[j]  = sprite_sx[j] + (8 << sprite_enlarged);
      assign sprite_exl[j] = sprite_sx[j] + ((8 << sprite_enlarged) << sprite_large);
      assign sprite_sy1[j] = sprite_y[j] + 33;
      assign sprite_ey1[j] = sprite_sy1[j] + ((8 << sprite_enlarged) << sprite_large);
      // Mode 4
      assign sprite_color4[j] = {sprite_font3[j][sind], sprite_font2[j][sind], sprite_font1[j][sind], sprite_font[j][sind]};
    end
  endgenerate

  // VRAM
  reg [13:0] vid_addr;
  wire [7:0] vid_out; 

  // Set horizontal and vertical counters, generate sync signals and
  // vertical sync interrupt interrupt
  always @(posedge clk) begin
    if (reset) begin
      intCnt <= 1;
      hc <= 0;
      vc <= 0;
    end else begin
      if (hc == HT - 1) begin
        hc <= 0;
        if (vc == VT - 1) begin
          vc <= 0;
          r_y_scroll <= y_scroll;
        end else vc <= vc + 1;
      end else hc <= hc + 1;
      if (hc == HA + HFP && vc == VA + VFP && vert_retrace_int) INT <= 1;
      if (INT) intCnt <= intCnt + 1;
      if (!intCnt) INT <= 0;
    end
  end

  vram video_ram (
    .clk_a(cpu_clk),
    .addr_a(vga_addr),
    .we_a(vga_wr && !cram_selected),
    .re_a(vga_rd),
    .din_a(vga_din),
    .dout_a(vga_dout),
    .clk_b(clk),
    .addr_b(vid_addr),
    .dout_b(vid_out)
  );

  // Set the palettes for mode 4
  always @(posedge cpu_clk) begin
    if (vga_wr && cram_selected) begin
      if (vga_addr < 16) begin
        colors1[vga_addr] <= {vga_din[1:0], 6'b0, vga_din[3:2], 6'b0, vga_din[5:4], 6'b0};
      end else if (vga_addr < 32) begin
        colors2[vga_addr - 16] <= {vga_din[1:0], 6'b0, vga_din[3:2], 6'b0, vga_din[5:4], 6'b0};
      end
    end
  end

  // Calculate x_char and x_pix for mode 0
  always @(posedge clk) begin
    if (hc[0] == 1) begin
      x_pix <= x_pix + 1;
      if (x_pix == (char_width - 1)) begin
        x_pix <= 0;
        x_char <= x_char + 1;
      end
    end

    // Get ready for start of line
    if (hc == HB - (char_width << 1) - 1) begin
      x_pix <= 0;
      x_char <= 63;
    end
  end

  integer i;
  // Index of sprite during sprite scan
  wire [1:0] sprite_index = (hc[5:1] - 1) >> 2;

  // Fetch VRAM data and create pixel output
  always @(posedge clk) begin
    if (reset) begin
      screen_color <= 0;
    end else if (video_on) begin
      if (mode == 0) begin
        sprite_pixel <= 0;
        num_sprites <= 0;
        if (hc[0] == 1) begin
          if (x_pix == 3) begin
            // Set address for next character
            vid_addr <= name_table_addr + (y[7:3] * 40 + x_char + 1);
          end else if (x_pix == 4) begin
            // Set address for font line
            vid_addr <= font_addr + {vid_out, y[2:0]};
          end else if (x_pix == 5) begin
            // Store the font line ready for next character
            font_line <= vid_out;
          end
        end
      end else begin
        if (mode == 1 || mode == 2) begin
          // In screen mode 1, 32 entries in color table specify the colors for
          // groups of 8 characters.
          // In screen mode 2, there are two colors for each line of 8 pixels,
          // the screen is 256x192 pixels,
          // Fetch the colors on even cycles (could be merged with pattern fetch).
          if (hc[0] == 0 && hc < HA) begin
            // Get the colors
            if (x_pix == 5) begin
              // Set address for next character
              vid_addr <= name_table_addr + {y[7:3], next_char};
            end else if (x_pix == 6) begin
              // Set address for next color block
              if (mode == 2) vid_addr <= color_table_addr + {y[7:6], 11'b0} + {vid_out, y[2:0]};
              else vid_addr <= color_table_addr + vid_out[7:3];
            end else if (x_pix == 7) begin
              // Store the color block ready for next character
              screen_color_next <= vid_out;
            end
          end
        end
        // Fetch the pattern data, on odd cycles
        if (hc[0] == 1) begin
          if (hc < HA) begin
            if (mode == 4) begin
              screen_color <= 8'h65;
              if (x_scroll_pix == 0) begin
                vid_addr <= name_table_addr + {y_char_scroll, next_scroll, 1'b0};
              end else if (x_scroll_pix == 1) begin
                first_index_byte <= vid_out;
                vid_addr <= vid_addr + 1;
              end else if (x_scroll_pix == 2) begin
                second_index_byte <= vid_out;
                vid_addr <= font_addr + {vid_out[0], first_index_byte, (vid_out[2] ? ~y_scroll_pix : y_scroll_pix), 2'b0};
              end else if (x_scroll_pix < 7) begin
                vid_addr <= vid_addr + 1;
                bit_plane_next[x_scroll_pix - 3] <= vid_out;
              end else if (x_scroll_pix == 7) begin
                for(i=0;i<4;i++) bit_plane[i] <= bit_plane_next[i];
                h_flip <= second_index_byte[1];
                palette <= second_index_byte[3];
                priority = second_index_byte[4];
              end
            end else begin
              // Fetch the font for screen mode 1 to 3
              if (x_pix == 5) begin
                // Set address for next character
                vid_addr <= name_table_addr + {y[7:3], next_char};
              end else if (x_pix == 6) begin
                // Set address for font line, 3 blocks if mode == 2
                if (mode == 3) vid_addr <= font_addr + {vid_out, y[4:2]};
                else vid_addr <= font_addr + (mode == 2 ? {y[7:6] , 11'b0} : 13'b0) +  {vid_out, y[2:0]};
              end else if (x_pix == 7) begin
                // Store the font line (or colors for mode 3) ready for next character
                font_line <= vid_out;
                // For modes 1 or  2, set screen color for next block
                if (mode == 1 || mode == 2) begin
                  screen_color <= screen_color_next;
                end
              end
            end
            // Position the sprites
            sprite_pixel <= 0;
            if (mode != 4) begin
              for(i=0;i<NUM_ACTIVE_SPRITES;i=i+1) if (i < num_sprites) begin
                // Set the sprite fonts
                if (x34 == sprite_sx[i])
                  sprite_line[i] <= sprite_font[i];
                if (sprite_large && x34 == sprite_ex[i])
                  sprite_line[i] <= sprite_font1[i];
                // Look for up to 4 sprites on the current line
                if (y32 >= sprite_sy1[i] && y32 < sprite_ey1[i]) begin
                  if (x33 >= sprite_sx[i] && x33 < sprite_exl[i])
                    sprite_pixel[i] <= (sprite_line[i][~sprite_col[i]]);
                end
              end 
            end else begin
              for(i=0;i<NUM_ACTIVE_SPRITES;i=i+1) begin
                if (i < num_sprites) begin
                  //if (y + 1 >= sprite_y[i] && y + 1 < sprite_y[i] + 8 + (sprite_enlarged ? 8 : 0)) begin
                    if (x >= sprite_x[i] && x < sprite_x[i] + 8 + (sprite_enlarged ? 8 : 0)) begin
                      sprite_pixel[i] <= sprite_color4[i] != 0;;
                    end
                  //end
                end
              end
            end
            // Initialisation for sprite scan
            if (hc == HA - 1 && vc[0] == 1) begin
              num_sprites <= 0;
              sprites_done <= 0;
              spritex <= 5'h1f;
            end
          // End of active area, fetch data for next line
          end else begin // Read sprite attributes and patterns
            if (mode == 4) begin
              if (vc[0] == 1) begin
                if (hc >= HA && hc < SPRITE_SCAN_END) begin
                  vid_addr <= sprite_attr_addr + hc[6:1]; // Address of y attribute
                end
                if (hc >= HA + 2 && hc < SPRITE_SCAN_END + 2 && !sprites_done) begin
                  if (vid_out == 208) sprites_done <= 1;
                  else if (y >= vid_out && y < vid_out + 8 + (sprite_enlarged ? 8 : 0)) begin
                    if (num_sprites < NUM_ACTIVE_SPRITES) begin
                      sprite_num[num_sprites] <= hc[6:1] - 1;
                      sprite_y[num_sprites] <= vid_out;
                      num_sprites <= num_sprites + 1;
                    end else begin
                      sprites_done <= 1;
                    end
                  end
                end
                // Read the sprite x values for the row
                if (hc >= SPRITE_SCAN_END && hc < SPRITE_SCAN_END + 16) 
                  vid_addr <= sprite_attr_addr + 128 + {sprite_num[hc[3:1]], 1'b0};
                if (hc >= SPRITE_SCAN_END + 2 && hc < SPRITE_SCAN_END + 18)
                  sprite_x[hc[3:1] - 1] <= vid_out;
                // Read the pattern number values for the row
                if (hc >= SPRITE_SCAN_END + 16 && hc < SPRITE_SCAN_END + 32) 
                  vid_addr <= sprite_attr_addr + 128 + {sprite_num[hc[3:1]], 1'b1};
                if (hc >= SPRITE_SCAN_END + 18 && hc < SPRITE_SCAN_END + 34)
                  sprite_pattern[hc[3:1] - 1] <= vid_out;
                // Read the sprite bit planes for the row
                if (hc >= SPRITE_SCAN_END + 32 && hc < SPRITE_SCAN_END + 48)
                    vid_addr <= sprite_pattern_table_addr + {sprite_pattern[sprite_num[hc[3:1]]], ysp, 2'b00};
                if (hc >= SPRITE_SCAN_END + 34 && hc < SPRITE_SCAN_END + 50)
                    sprite_font[hc[3:1] - 1] <= vid_out;
                if (hc >= SPRITE_SCAN_END + 48 && hc < SPRITE_SCAN_END + 64)
                    vid_addr <= sprite_pattern_table_addr + {sprite_pattern[sprite_num[hc[3:1]]], ysp, 2'b01};
                if (hc >= SPRITE_SCAN_END + 50 && hc < SPRITE_SCAN_END + 66)
                    sprite_font1[hc[3:1] - 1] <= vid_out;
                if (hc >= SPRITE_SCAN_END + 64 && hc < SPRITE_SCAN_END + 80)
                    vid_addr <= sprite_pattern_table_addr + {sprite_pattern[sprite_num[hc[3:1]]], ysp, 2'b10};
                if (hc >= SPRITE_SCAN_END + 66 && hc < SPRITE_SCAN_END + 82)
                    sprite_font2[hc[3:1] - 1] <= vid_out;
                if (hc >= SPRITE_SCAN_END + 80 && hc < SPRITE_SCAN_END + 96)
                    vid_addr <= sprite_pattern_table_addr + {sprite_pattern[sprite_num[hc[3:1]]], ysp, 2'b11};
                if (hc >= SPRITE_SCAN_END + 82 && hc < SPRITE_SCAN_END + 98)
                    sprite_font3[hc[3:1] - 1] <= vid_out;
              end

            end else begin
              // Look at up to 32 sprites
              if (vc[0] == 1) begin
                if (hc >= HA && hc < SPRITE_SCAN_END) begin
                  // Fetch y attribute
                  vid_addr <= sprite_attr_addr + {hc[5:1], 2'b0};
                end
                // Check if sprite is on the line
                if (hc >= HA + 2 && hc < SPRITE_SCAN_END + 2 && !sprites_done) begin
                   if (vid_out == 208) sprites_done <= 1;
                   else if (y32 >= sprite_sy && y32 < sprite_ey) begin
                     if (num_sprites < 4) begin
                       sprite_num[num_sprites] <= hc[5:1] - 1;
                       num_sprites <= num_sprites + 1;
                     end else begin
                       spritex <= hc[5:1] - 1;
                       sprites_done <= 1;
                     end
                  end
                end
                // Read the sprite attributes for the row
                if (hc >= SPRITE_SCAN_END && hc < SPRITE_ATTR_SCAN_END) 
                  vid_addr <= sprite_attr_addr + {sprite_num[hc[4:3]], hc[2:1]};
                if (hc >= SPRITE_SCAN_END + 2 && hc < SPRITE_ATTR_SCAN_END + 2) begin
                  case ((hc[3:1] - 1) & 2'b11)
                    0: sprite_y[sprite_index] <= vid_out;
                    1: sprite_x[sprite_index] <= vid_out;
                    2: sprite_pattern[sprite_index] <= vid_out;
                    3: begin
                         sprite_color[sprite_index] <= vid_out[3:0];
                         sprite_ec[sprite_index] <= vid_out[7];
                       end
                  endcase
                end 
                // Read the sprite patterns for the row
                if (hc >= SPRITE_ATTR_SCAN_END && hc < SPRITE_PATTERN_SCAN_END)
                  if (sprite_large) 
                    vid_addr <= sprite_pattern_table_addr + 
                                {sprite_pattern[hc[2:1]][7:2],1'b0, sprite_row[hc[2:1]][3:0]};
                  else
                    vid_addr <= sprite_pattern_table_addr + 
                                {sprite_pattern[hc[2:1]], sprite_row[hc[2:1]][2:0]};

                if (hc >= SPRITE_ATTR_SCAN_END + 2 && hc < SPRITE_PATTERN_SCAN_END + 2) 
                  sprite_font[hc[2:1]-1] <= vid_out;
        
                if (sprite_large) begin
                  if (hc >= SPRITE_PATTERN_SCAN_END  && hc < SPRITE_PATTERN2_SCAN_END) 
                    vid_addr <= sprite_pattern_table_addr + 
                                {sprite_pattern[hc[2:1]][7:2],1'b1, sprite_row[hc[2:1]][3:0]};

                  if (hc >= SPRITE_PATTERN_SCAN_END + 2 && hc < SPRITE_PATTERN2_SCAN_END + 2)
                    sprite_font1[hc[2:1]-1] <= vid_out;
                end
              end
            end
          end
        end
      end
    end
  end

  // Set the pixel from highest priority plane 
  wire [2:0] index = h_flip ? x_scroll_pix : ~x_scroll_pix;

  // Pixel priority
  wire [3:0] pixel_color = mode != 4 && sprite_pixel[0] ? sprite_color[0] : 
                           mode != 4 && sprite_pixel[1] ? sprite_color[1] :
                           mode != 4 && sprite_pixel[2] ? sprite_color[2] :
                           mode != 4 && sprite_pixel[3] ? sprite_color[3] : 
                           mode == 4 & sprite_pixel[0] ? sprite_color4[0] :
                           mode == 4 & sprite_pixel[1] ? sprite_color4[1] :
                           mode == 4 & sprite_pixel[2] ? sprite_color4[2] :
                           mode == 4 & sprite_pixel[3] ? sprite_color4[3] :
                           mode == 4 & sprite_pixel[4] ? sprite_color4[4] :
                           mode == 4 & sprite_pixel[5] ? sprite_color4[5] :
                           mode == 4 & sprite_pixel[6] ? sprite_color4[6] :
                           mode == 4 & sprite_pixel[7] ? sprite_color4[7] :
                           mode == 0 ? (font_line[~x_pix] ? text_color : back_color) :
                           mode == 3 ? (x_pix < 4 ? font_line[7:4] : font_line[3:0]) :
                           mode == 4 ? {bit_plane[3][index], bit_plane[2][index], bit_plane[1][index], bit_plane[0][index]} :
                           font_line[~x_pix] ? screen_color[7:4] : screen_color[3:0];

  // Set the 24-bit color value, taking border into account
  wire [3:0] col = border ? back_color : pixel_color;
  wire [23:0] color = palette || sprite_pixel != 0 || border ? colors2[col] : colors1[col];

  // Set the 8-bit VGA output signals
  assign vga_r = !vga_de ? 8'b0 : color[23:16];
  assign vga_g = !vga_de ? 8'b0 : color[15:8];
  assign vga_b = !vga_de ? 8'b0 : color[7:0];

  // LED diagnostics
  always @(posedge clk) diag = {sprite_font1[0], sprite_font2[0]};

endmodule
