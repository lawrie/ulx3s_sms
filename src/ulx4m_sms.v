`default_nettype none
`define ulx4m
module sms
#(
  parameter c_vga_out      = 0, // 0; Just HDMI, 1: VGA and HDMI
  parameter c_lcd_hex      = 0, // SPI LCD HEX decoder
  parameter C_flash_loader = 1, // fujprog -j flash -f 0x200000 100in1.img
  parameter C_esp32_loader = 0, // Needs import osd on ESP32 
  parameter c_diag         = 0, // 0: No led diagnostcs, 1: led diagnostics 
  parameter c_volume       = 4  // Sound volume 0 - 15
)
(
  input         clk_25mhz,

  // Flash
  output flash_csn,
  output flash_mosi,
  output flash_wpn,
  output flash_holdn,
  input  flash_miso,

  // Buttons
`ifdef ulx3s
  input [6:0]   btn,
`else
  input [2:1]   btn,
`endif

  // HDMI
  output [3:0]  gpdi_dp,
  output [3:0]  gpdi_dn,

  // Keyboard
  output        usb_fpga_pu_dp,
  output        usb_fpga_pu_dn,

`ifdef ulx3s
  // Audio
  output [3:0]  audio_l,
  output [3:0]  audio_r,
`endif

`ifdef ulx3s
  // ESP32 passthru
  input         ftdi_txd,
  output        ftdi_rxd,
  input         wifi_txd,
  output        wifi_rxd,  // SPI from ESP32
  input         wifi_gpio16,
  input         wifi_gpio5,
  output        wifi_gpio0,
 `endif
 
  inout  sd_clk, sd_cmd,
  inout   [3:0] sd_d,

  output sdram_csn,       // chip select
  output sdram_clk,       // clock to SDRAM
  output sdram_cke,       // clock enable to SDRAM
  output sdram_rasn,      // SDRAM RAS
  output sdram_casn,      // SDRAM CAS
  output sdram_wen,       // SDRAM write-enable
  output [12:0] sdram_a,  // SDRAM address bus
  output  [1:0] sdram_ba, // SDRAM bank-address
  output  [1:0] sdram_dqm,// byte select
  inout  [15:0] sdram_d,  // data bus to/from SDRAM

`ifdef ulx3s
  inout  [27:0] gp,gn,
`endif

`ifdef ulx3s
  // SPI display
  output        oled_csn,
  output        oled_clk,
  output        oled_mosi,
  output        oled_dc,
  output        oled_resn,
`endif

`ifdef ulx4m
  //Gpio
  output [19:18] gpio,
`endif
  
  // Leds
`ifdef ulx3x
  output [7:0]  led
`else
  output [3:0]  led
`endif

);

  // prevent crosstalk at flash unused lines
  assign flash_wpn = 1;
  assign flash_holdn = 1;
  wire flash_sck;
  wire tristate = 1'b0;
  USRMCLK u1 (.USRMCLKI(flash_sck), .USRMCLKTS(tristate));

  // I/O ports
  wire vdp_data_port = cpuAddress[7:6] == 2 && !cpuAddress[0];
  wire vdp_ctrl_port = cpuAddress[7:6] == 2 && cpuAddress[0];

  wire psg_write_port = cpuAddress[7:6] == 1 && cpuAddress[0];

  wire joypad_0_port = cpuAddress[7:6] == 3 && !cpuAddress[0];
  wire joypad_1_port = cpuAddress[7:6] == 3 && cpuAddress[0];

  wire mem_ctrl_port = cpuAddress[7:6] == 0 && !cpuAddress[0];
  wire joypad_ctrl_port = cpuAddress[7:6] == 0 && cpuAddress[0];

  wire v_counter_port = cpuAddress[7:6] == 1 && !cpuAddress[0];
  wire h_counter_port = cpuAddress[7:6] == 1 && cpuAddress[0];

  wire [7:0] v_counter;
  wire [7:0] h_counter;

  reg [7:0] r_mem_ctrl;
  reg [7:0] r_joy_ctrl;

  // pull-ups for us2 connector 
  assign usb_fpga_pu_dp = 1;
  assign usb_fpga_pu_dn = 1;
  
  // passthru to ESP32 micropython serial console
`ifdef ulx3s
  assign wifi_rxd = ftdi_txd;
  assign ftdi_rxd = wifi_txd;
`endif

  // VGA (should be assigned to some gp/gn outputs
  wire   [7:0]  red;
  wire   [7:0]  green;
  wire   [7:0]  blue;
  wire          hSync;
  wire          vSync;
  
  generate
    genvar i;
    if (c_vga_out) begin
      for(i = 0; i < 4; i = i+1) begin
        assign gp[10-i] = blue[4+i];
        assign gn[3-i] = green[4+i];
        assign gn[10-i] = red[4+i];
      end
      assign gp[2] = vSync;
      assign gp[3] = hSync;
    end 
  endgenerate

  // Led diagnostics
  reg [15:0] diag16;

  generate 
    genvar i;
    if (c_diag) begin
      for(i = 0; i < 4; i = i+1) begin
        assign gn[17-i] = diag16[8+i];
        assign gp[17-i] = diag16[12+i];
        assign gn[24-i] = diag16[i];
        assign gp[24-i] = diag16[4+i];
      end
    end
  endgenerate
  
  // CPU registers
  wire          n_WR;
  wire          n_RD;
  wire          n_INT;
  wire [15:0]   cpuAddress;
  wire [7:0]    cpuDataOut;
  wire [7:0]    cpuDataIn;
  wire          n_memWR;
  wire          n_memRD;
  wire          n_ioWR;
  wire          n_ioRD;
  wire          n_MREQ;
  wire          n_IORQ;
  wire          n_M1;
  wire          n_kbdCS;
  wire          n_int;

  reg [2:0]     cpuClockCount;
  wire          cpuClockEnable;
  reg           cpuClockEnable1; 
  wire          cpuClockEdge = cpuClockEnable && !cpuClockEnable1;
  wire [7:0]    ramOut;
  wire [7:0]    biosOut;
  wire [7:0]    romOut;

  reg [7:0]   slot0, slot1, slot2;
  reg [7:0]   mem_misc;
  
  // ===============================================================
  // System Clock generation
  // ===============================================================
  wire clk_sdram_locked;
  wire [3:0] clocks;
  ecp5pll
  #(
      .in_hz( 25*1000000),
    .out0_hz(125*1000000),
    .out1_hz( 25*1000000),
    .out2_hz(100*1000000),                // SDRAM core
    .out3_hz(100*1000000), .out3_deg(180) // SDRAM chip 45-330:ok 0-30:not
  )
  ecp5pll_inst
  (
    .clk_i(clk_25mhz),
    .clk_o(clocks),
    .locked(clk_sdram_locked)
  );
  wire clk_hdmi  = clocks[0];
  wire clk_vga   = clocks[1];
  wire cpuClock  = clocks[1];
  wire clk_sdram = clocks[2];
  wire sdram_clk = clocks[3]; // phase shifted for chip

  // ===============================================================
  // Joystick for OSD control and games
  // ===============================================================
  reg joypad2 = 0;
  reg [6:0] R_btn_joy;
  always @(posedge cpuClock)
`ifdef ulx3s
    R_btn_joy <= btn;
`else
    R_btn_joy <= {4'b0, btn, 1'b1};
`endif

  // ===============================================================
  // SPI Slave for RAM and CPU control
  // ===============================================================
  wire        spi_ram_wr, spi_ram_rd;
  wire [31:0] spi_ram_addr;
  wire  [7:0] spi_ram_di;
  wire  [7:0] spi_ram_do = ramOut;

  assign sd_d[0] = 1'bz;
  assign sd_d[3] = 1'bz; // FPGA pin pullup sets SD card inactive at SPI bus

  wire irq;
  spi_ram_btn
  #(
    .c_sclk_capable_pin(1'b0),
    .c_addr_bits(32)
  )
  spi_ram_btn_inst
  (
    .clk(cpuClock),
`ifdef ulx3s
    .csn(~wifi_gpio5),
    .sclk(wifi_gpio16),
`else
    .csn(1'b1),
    .sclk(1'b0),
`endif
    .mosi(sd_d[1]), // wifi_gpio4
    .miso(sd_d[2]), // wifi_gpio12
    .btn(R_btn_joy),
    .irq(irq),
    .wr(spi_ram_wr),
    .rd(spi_ram_rd),
    .addr(spi_ram_addr),
    .data_in(spi_ram_do),
    .data_out(spi_ram_di)
  );
  // Used for interrupt to ESP32
`ifdef ulx3s
  assign wifi_gpio0 = ~irq;
`endif 

  reg [7:0] R_cpu_control = 0;
  always @(posedge cpuClock) begin
    if (spi_ram_wr && spi_ram_addr[31:24] == 8'hFF) begin
      R_cpu_control <= spi_ram_di;
    end
  end

  // ===============================================================
  // Reset generation
  // ===============================================================
  reg [15:0] pwr_up_reset_counter = 0;
  wire       pwr_up_reset_n = &pwr_up_reset_counter;

  always @(posedge cpuClock) begin
     if (!pwr_up_reset_n)
       pwr_up_reset_counter <= pwr_up_reset_counter + 1;
  end

  wire load_done;
  wire  [7:0] flash_loader_data_out;
  wire [21:0] flash_loader_addr;
  wire flash_loader_data_ready;
  wire loader_write;

  generate
  if(C_flash_loader)
  begin
  flash_loader
  flash_load_i
  (
    .clock(cpuClock),
    .reset(reset),
    .reload(1'b0),
    .index({4'b0000}),
    .load_addr(flash_loader_addr),
    .load_write_data(flash_loader_data_out),
    .data_valid(flash_loader_data_ready),
    .load_done(load_done),
    //Flash load interface
    .flash_csn(flash_csn),
    .flash_sck(flash_sck),
    .flash_mosi(flash_mosi),
    .flash_miso(flash_miso)
  );
  end
  endgenerate

  // ===============================================================
  // CPU
  // ===============================================================
  wire [15:0] pc;
  
  reg n_hard_reset;
  always @(posedge cpuClock)
`ifdef ulx3s
    n_hard_reset <= pwr_up_reset_n & btn[0] & ~R_cpu_control[0];
`else
    n_hard_reset <= pwr_up_reset_n & ~btn[1] & ~R_cpu_control[0];
`endif

  wire reset = !n_hard_reset;

  tv80n cpu1 (
    .reset_n(n_hard_reset & load_done),
    .clk(cpuClockEnable), // normal mode 3.5MHz
    //.wait_n(!R_btn_joy[1]),
    .wait_n(1'b1),
    .int_n(n_int),
    .nmi_n(1'b1),
    .busrq_n(1'b1),
    .mreq_n(n_MREQ),
    .m1_n(n_M1),
    .iorq_n(n_IORQ),
    .wr_n(n_WR),
    .rd_n(n_RD),
    .A(cpuAddress),
    .di(cpuDataIn),
    .do(cpuDataOut),
    .pc(pc)
  );

  // ===============================================================
  // RAM
  // ===============================================================
  ram ram8k (
    .clk(cpuClock),
    .we(cpuAddress[15:14] == 3 && !n_memWR),
    .addr(cpuAddress[12:0]),
    .din(cpuDataOut),
    .dout(ramOut)
  );

  // ===============================================================
  // GAME ROM (uses SDRAM)
  // ===============================================================
  wire sdram_d_wr;
  wire [15:0] sdram_d_in, sdram_d_out;
  wire [23:0] sdramAddress = cpuAddress[15:14] == 0 ? {slot0, cpuAddress[13:0]} :
                    cpuAddress[15:14] == 1 ? {slot1, cpuAddress[13:0]} :
                    cpuAddress[15:14] == 2 ? {slot2, cpuAddress[13:0]} : cpuAddress;

  assign sdram_d = sdram_d_wr ? sdram_d_out : 16'hzzzz;
  assign sdram_d_in = sdram_d;
  sdram
  sdram_i
  (
   .sd_data_in(sdram_d_in),
   .sd_data_out(sdram_d_out),
   .sd_addr(sdram_a),
   .sd_dqm(sdram_dqm),
   .sd_cs(sdram_csn),
   .sd_ba(sdram_ba),
   .sd_we(sdram_wen),
   .sd_ras(sdram_rasn),
   .sd_cas(sdram_casn),
   // system interface
   .clk(clk_sdram),
   .clkref(cpuClockEnable),
   .init(!clk_sdram_locked),
   .we_out(sdram_d_wr),
   // cpu/chipset interface
   .weA(0),
   .addrA(sdramAddress),
   .oeA(cpuClockEnable),
   .dinA(0),
   .doutA(romOut),
   // SPI interface
   //.weB(spi_ram_wr && spi_ram_addr[31:24] == 8'h00),
   //.addrB(spi_ram_addr[23:0]),
   //.dinB(spi_ram_di),
   .weB(!load_done && flash_loader_data_ready),
   .addrB(flash_loader_addr),
   .dinB(flash_loader_data_out),
   .oeB(0),
   .doutB()
  );
  
  // ===============================================================
  // BIOS ROM
  // ===============================================================
  rom #(.MEM_INIT_FILE("../roms/bios.mem")) bios_rom (
    .clk(cpuClock),
    .addr(cpuAddress[13:0]),
    .dout(biosOut)
  );

  // ===============================================================
  // VGA
  // ===============================================================
  wire        vga_de;
  wire [7:0]  vga_dout;
  reg [13:0]  vga_addr;
  wire        vga_wr = vdp_data_port && n_ioWR == 1'b0;
  wire        vga_rd = vdp_data_port && n_ioRD == 1'b0;
  reg         is_second_addr_byte = 0;
  reg [7:0]   first_addr_byte;
  reg [7:0]   r_vdp [0:10];
  wire        m1 = r_vdp[1][4];
  wire        m2 = r_vdp[0][1];
  wire        m3 = r_vdp[1][3];
  wire        m4 = r_vdp[0][2];
  wire [2:0]  mode = m4 ? 4 : m3 ? 3 : m2 ? 2 : m1 ? 1 : 0;
  wire [13:0] name_table_addr = {r_vdp[2][3:1], 11'b0};
  wire [13:0] color_table_addr = mode == 2 ? {r_vdp[3][7], 13'b0} : {r_vdp[3], 6'b0};
  wire [13:0] font_addr = mode == 4 ? 0 : mode == 2 ? {r_vdp[4][2],13'b0} : {r_vdp[4], 11'b0};
  wire [13:0] sprite_attr_addr = {r_vdp[5][6:1], 8'b0};
  wire [13:0] sprite_pattern_table_addr = mode == 4 ? {r_vdp[6][2], 13'b0} : {r_vdp[6][2:0], 11'b0};
  wire [3:0]  overscan_color = r_vdp[7][3:0];
  wire [7:0]  x_scroll = r_vdp[8];
  wire [7:0]  y_scroll = r_vdp[9];
  wire [7:0]  line_counter = r_vdp[10];
  wire [15:0] vga_diag;
  reg         r_vga_rd;
  wire [4:0]  spritex;
  wire        sprite_collision;
  wire        too_many_sprites;
  wire        interrupt_flag;
  reg         cram_selected;

  // I/O ports
  always @(posedge cpuClock) begin
    if (!n_hard_reset) begin
      r_mem_ctrl <= 8'hf7;
      slot0 <= 0;
      slot1 <= 1;
      slot2 <= 2;
      mem_misc <= 0;
      r_joy_ctrl <= 0;
    end else if (cpuClockEdge) begin
      // VDP interface
      if (vga_wr) vga_addr <= vga_addr + 1;
      // Increment address on CPU cycle after IO read
      r_vga_rd <= vga_rd;
      if (r_vga_rd && !vga_rd) vga_addr <= vga_addr + 1;

      // Clear second address byte flag on VDP ctrl read or data read or write
      if ((vdp_ctrl_port && n_ioRD == 1'b0) || vga_rd || vga_wr) is_second_addr_byte <= 0;
      if (vdp_ctrl_port && n_ioWR == 1'b0) begin
        is_second_addr_byte <= ~is_second_addr_byte;
        if (is_second_addr_byte) begin
          if (!cpuDataOut[7]) begin // Ignores bit 6 which says if VRAM read or write is coming next
            vga_addr <= {cpuDataOut[5:0], first_addr_byte};
            cram_selected <= 0;
          end else if (cpuDataOut[7:6] == 3) begin // CRAM
            vga_addr <= first_addr_byte[5:0];
            cram_selected <= 1;
          end else if (cpuDataOut[7:6] == 2 && cpuDataOut[3:0] < 11) begin
            r_vdp[cpuDataOut[3:0]] <= first_addr_byte;
          end else begin 
            vga_addr <= first_addr_byte[5:0];
            cram_selected <= 1;
          end
        end else
          first_addr_byte <= cpuDataOut;
      end else if (mem_ctrl_port && n_ioWR == 1'b0) begin
        r_mem_ctrl <= cpuDataOut; // Memory control write
      end else if (joypad_ctrl_port && n_ioWR == 1'b0) begin
        r_joy_ctrl <= cpuDataOut;
      end

      if (cpuAddress == 16'hfffc && n_memWR == 1'b0) mem_misc <= cpuDataOut;
      else if (cpuAddress == 16'hfffd && n_memWR == 1'b0) slot0 <= cpuDataOut;
      else if (cpuAddress == 16'hfffe && n_memWR == 1'b0) slot1 <= cpuDataOut;
      else if (cpuAddress == 16'hffff && n_memWR == 1'b0) slot2 <= cpuDataOut;
    end
  end
      
  video vga (
    .clk(clk_vga),
    .reset(reset),
    .vga_r(red),
    .vga_g(green),
    .vga_b(blue),
    .vga_de(vga_de),
    .vga_hs(hSync),
    .vga_vs(vSync),
    .vga_addr(vga_addr),
    .vga_din(cpuDataOut),
    .vga_dout(vga_dout),
    .vga_wr(vga_wr && cpuClockEdge),
    .vga_rd(vga_rd && cpuClockEdge),
    .mode(mode),
    .cpu_clk(cpuClock),
    .font_addr(font_addr),
    .name_table_addr(name_table_addr),
    .color_table_addr(color_table_addr),
    .sprite_attr_addr(sprite_attr_addr),
    .sprite_pattern_table_addr(sprite_pattern_table_addr),
    .n_int(n_int),
    .video_on(r_vdp[1][6]),
    .text_color(r_vdp[7][7:4]),
    .back_color(r_vdp[7][3:0]),
    .sprite_large(r_vdp[1][1]),
    .sprite_enlarged(r_vdp[1][0]),
    .vert_retrace_int(r_vdp[1][5]),
    .sprite_collision(sprite_collision),
    .too_many_sprites(too_many_sprites),
    .spritex(spritex),
    .interrupt_flag(interrupt_flag),
    .x_scroll(x_scroll),
    .y_scroll(y_scroll),
    .cram_selected(cram_selected),
    .disable_vert(r_vdp[0][7]),
    .disable_horiz(r_vdp[0][6]),
    .lines224(r_vdp[0][1] & r_vdp[1][4]),
    .lines240(r_vdp[0][1] & r_vdp[1][3]),
    .mask_col0(r_vdp[0][5]),
    .v_counter(v_counter),
    .h_counter(h_counter),
    .diag(vga_diag)
  );

  // ===============================================================
  // SPI Slave for OSD display
  // ===============================================================

  wire [7:0] osd_vga_r, osd_vga_g, osd_vga_b;
  wire osd_vga_hsync, osd_vga_vsync, osd_vga_blank;
  spi_osd
  #(
    .c_start_x(62), .c_start_y(80),
    .c_chars_x(64), .c_chars_y(20),
    .c_init_on(0),
    .c_transparency(1),
    .c_char_file("osd.mem"),
    .c_font_file("font_bizcat8x16.mem")
  )
  spi_osd_inst
  (
    .clk_pixel(clk_vga), .clk_pixel_ena(1),
    .i_r(red  ),
    .i_g(green),
    .i_b(blue ),
    .i_hsync(~hSync), .i_vsync(~vSync), .i_blank(~vga_de),
`ifdef ulx3s
    .i_csn(~wifi_gpio5), .i_sclk(wifi_gpio16), .i_mosi(sd_d[1]), // .o_miso(),
`else
    .i_csn(1'b1), .i_sclk(1'b0), .i_mosi(sd_d[1]), // .o_miso(),
`endif
    .o_r(osd_vga_r), .o_g(osd_vga_g), .o_b(osd_vga_b),
    .o_hsync(osd_vga_hsync), .o_vsync(osd_vga_vsync), .o_blank(osd_vga_blank)
  );

  // Convert VGA to HDMI
  HDMI_out vga2dvid (
    .pixclk(clk_vga),
    .pixclk_x5(clk_hdmi),
`ifdef ulx3s
    .red  (osd_vga_r),
    .green(osd_vga_g),
    .blue (osd_vga_b),
    .vde  (~osd_vga_blank),
    .hSync(~osd_vga_hsync),
    .vSync(~osd_vga_vsync),
`else
    .red  (red),
    .green(green),
    .blue (blue),
    .vde  (vga_de),
    .hSync(hSync),
    .vSync(vSync),
`endif
    .gpdi_dp(gpdi_dp),
    .gpdi_dn(gpdi_dn)
  );
  // ===============================================================
  // MEMORY READ/WRITE LOGIC
  // ===============================================================

  assign n_ioWR  = n_WR | n_IORQ;
  assign n_memWR = n_WR | n_MREQ;
  assign n_ioRD  = n_RD | n_IORQ;
  assign n_memRD = n_RD | n_MREQ;

  // ===============================================================
  // Memory decoding
  // ===============================================================

  reg  r_interrupt_flag, r_sprite_collision;
  reg  r_status_read;
  wire [7:0] status = {r_interrupt_flag, too_many_sprites, r_sprite_collision, (too_many_sprites ? spritex : 5'b11111)};
  wire [7:0] joy_data0 = joypad2 ? {R_btn_joy[4:3], 6'b111111} : {2'b11, ~R_btn_joy[2:1], ~R_btn_joy[6:3]};
  wire [7:0] joy_data1 = joypad2 ? {4'b0101, R_btn_joy[2:1], R_btn_joy[6:5]} : {8'b10111111};

  assign cpuDataIn =  vdp_data_port && n_ioRD == 1'b0 ? vga_dout :
                      vdp_ctrl_port && n_ioRD == 1'b0 ? status :
		      // Controllers 0 and 1
		      joypad_0_port && n_ioRD == 1'b0 ? joy_data0 :
		      joypad_1_port && n_ioRD == 1'b0 ? joy_data1 :
                      // V and H counters
                      v_counter_port && n_ioRD == 1'b0 ? v_counter :
                      h_counter_port && n_ioRD == 1'b0 ? h_counter :
                      cpuAddress[15:14] < 3 && n_memRD == 1'b0 ? 
                        (r_mem_ctrl[3] == 0 ? biosOut : romOut) : ramOut;

  // Sprite collision interrupt
  always @(posedge cpuClock) begin
    if (!n_hard_reset) begin
      r_interrupt_flag <= 0;
      r_sprite_collision <= 0;
    end else begin
      if (interrupt_flag) r_interrupt_flag <= 1;
      if (sprite_collision) r_sprite_collision <= 1;
      if (cpuClockEdge) begin
        r_status_read <= vdp_ctrl_port && n_ioRD == 1'b0;
        if (r_status_read && !(vdp_ctrl_port && n_ioRD == 1'b0)) begin
          r_interrupt_flag <= 0;
          r_sprite_collision <= 0;
        end
      end
    end
  end
  
  // ===============================================================
  // CPU clock enable
  // ===============================================================
  
  always @(posedge cpuClock) begin
    cpuClockEnable1 <= cpuClockEnable;
    if(cpuClockCount == 6) // divide by 7: 25MHz/7 = 3.571MHz
      cpuClockCount <= 0;
    else
      cpuClockCount <= cpuClockCount + 1;
  end

  assign cpuClockEnable = cpuClockCount[2]; // 3.5Mhz

  // ===============================================================
  // Audio
  // ===============================================================
  wire [13:0] audio_dout;
  wire aud_l, aud_r;
  wire sound_ready;

  sn76489 #(14) sound (
    .clk(cpuClock),
    .clk_en(cpuClockEnable),
    .reset(!n_hard_reset),
    .ce_n(1'b0),
    .we_n(!(psg_write_port && n_ioWR == 1'b0)),
    .ready(sound_ready),
    .d(cpuDataOut),
    .audio_out(audio_dout)
  );

  // Use sigma-delta dac to get single-bit output
  sigma_delta_dac dac (
    .clk(cpuClock),
    .ldatasum(audio_dout),
    .rdatasum(audio_dout),
    .left(aud_l),
    .right(aud_r)
  );

`ifdef ulx3s
  assign audio_l = aud_l ? c_volume : 0;
  assign audio_r = audio_l;
`else
  assign gpio[18] = aud_l;
  assign gpio[19] = aud_r;
`endif

  // ===============================================================
  // Diagnostic LCD 
  // ===============================================================

  generate
  if(c_lcd_hex)
  begin
  // SPI DISPLAY
  reg [127:0] R_display;
  // HEX decoder does printf("%16X\n%16X\n", R_display[63:0], R_display[127:64]);
  always @(posedge cpuClock)
    R_display = {r_vdp[0], r_vdp[1], r_vdp[2], r_vdp[3], r_vdp[4], r_vdp[5],
                 r_vdp[6], r_vdp[7], r_vdp[8], r_vdp[9], r_vdp[10]};

  parameter C_color_bits = 16;
  wire [7:0] x;
  wire [7:0] y;
  wire [C_color_bits-1:0] color;
  hex_decoder_v
  #(
    .c_data_len(128),
    .c_row_bits(4),
    .c_grid_6x8(1), // NOTE: TRELLIS needs -abc9 option to compile
    .c_font_file("hex_font.mem"),
    .c_color_bits(C_color_bits)
  )
  hex_decoder_v_inst
  (
    .clk(clk_hdmi),
    .data(R_display),
    .x(x[7:1]),
    .y(y[7:1]),
    .color(color)
  );

  // allow large combinatorial logic
  // to calculate color(x,y)
  wire next_pixel;
  reg [C_color_bits-1:0] R_color;
  always @(posedge clk_hdmi)
    if(next_pixel)
      R_color <= color;

  wire w_oled_csn;
  lcd_video
  #(
    .c_clk_mhz(125),
    .c_init_file("st7789_linit_xflip.mem"),
    .c_clk_phase(0),
    .c_clk_polarity(1),
    .c_init_size(38)
  )
  lcd_video_inst
  (
    .clk(clk_hdmi),
    .reset(R_btn_joy[5]),
    .x(x),
    .y(y),
    .next_pixel(next_pixel),
    .color(R_color),
    .spi_clk(oled_clk),
    .spi_mosi(oled_mosi),
    .spi_dc(oled_dc),
    .spi_resn(oled_resn),
    .spi_csn(w_oled_csn)
  );
  //assign oled_csn = w_oled_csn; // 8-pin ST7789: oled_csn is connected to CSn
  assign oled_csn = 1; // 7-pin ST7789: oled_csn is connected to BLK (backlight enable pin)
  end
  endgenerate

  // ===============================================================
  // Leds
  // ===============================================================
  //assign led = {reset, 2'b0, load_done};

  always @(posedge cpuClock) if (flash_loader_addr == 1 && flash_loader_data_ready) led <= flash_loader_data_out << 2;
  always @(posedge cpuClock) diag16 <= {r_vdp[0], r_vdp[1]};

endmodule
