`default_nettype none
module sms
#(
  parameter c_vga_out     = 0, // 0; Just HDMI, 1: VGA and HDMI
  parameter c_diag        = 1  // 0: No led diagnostcs, 1: led diagnostics 
)
(
  input         clk_25mhz,
  // Buttons
  input [6:0]   btn,
  // Switches
  input [3:0]   sw,
  // HDMI
  output [3:0]  gpdi_dp,
  output [3:0]  gpdi_dn,
  // Keyboard
  output        usb_fpga_pu_dp,
  output        usb_fpga_pu_dn,
  inout         ps2Clk,
  inout         ps2Data,
  // Audio
  output [3:0]  audio_l,
  output [3:0]  audio_r,
  // ESP32 passthru
  input         ftdi_txd,
  output        ftdi_rxd,
  input         wifi_txd,
  output        wifi_rxd,  // SPI from ESP32
  input         wifi_gpio16,
  input         wifi_gpio5,
  output        wifi_gpio0,

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

  inout  [27:0] gp,gn,
  // Leds
  output [7:0]  led
);

  // Port numbers
  wire [7:0] vdp_ctrl_port = 8'hbf;
  wire [7:0] vdp_data_port = 8'hbe;

  wire [7:0] psg_write_port = 8'h7f;

  wire [7:0] ctrl_0_port = 8'hdc; // Not sure why there are 3 values
  wire [7:0] ctrl_1_port = 8'hdd; // for these ports
  wire [7:0] ctrl_2_port = 8'hde;

  wire [7:0] mem_ctrl_port = 8'h3e;

  reg [7:0] r_mem_ctrl;

  // pull-ups for us2 connector 
  assign usb_fpga_pu_dp = 1;
  assign usb_fpga_pu_dn = 1;
  
  // passthru to ESP32 micropython serial console
  assign wifi_rxd = ftdi_txd;
  assign ftdi_rxd = wifi_txd;

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
        assign gp[10-i] = red[4+i];
        assign gn[3-i] = green[4+i];
        assign gn[10-i] = blue[4+i];
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
  reg [6:0] R_btn_joy;
  always @(posedge cpuClock)
    R_btn_joy <= btn;

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
    .csn(~wifi_gpio5),
    .sclk(wifi_gpio16),
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
  assign wifi_gpio0 = ~irq;

  reg [7:0] R_cpu_control;
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

  // ===============================================================
  // CPU
  // ===============================================================
  wire [15:0] pc;
  
  reg n_hard_reset;
  always @(posedge cpuClock)
    n_hard_reset <= pwr_up_reset_n & btn[0] & ~R_cpu_control[0];

  wire reset = !n_hard_reset;

  wire sound_ready;

  tv80n cpu1 (
    .reset_n(n_hard_reset),
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
   .addrA(cpuAddress),
   .oeA(cpuClockEnable),
   .dinA(0),
   .doutA(romOut),
   // SPI interface
   .weB(spi_ram_wr && spi_ram_addr[31:24] == 8'h00),
   .addrB(spi_ram_addr[23:0]),
   .dinB(spi_ram_di),
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
  wire        vga_wr = cpuAddress[7:0] == vdp_data_port && n_ioWR == 1'b0;
  wire        vga_rd = cpuAddress[7:0] == vdp_data_port && n_ioRD == 1'b0;
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
  wire [4:0]  sprite5;
  wire        sprite_collision;
  wire        too_many_sprites;
  wire        interrupt_flag;
  reg         cram_selected;

  // I/O ports
  always @(posedge cpuClock) begin
    if (!n_hard_reset) begin
      r_mem_ctrl <= 8'hf7;
    end else if (cpuClockEdge) begin
      // VDP interface
      if (vga_wr) vga_addr <= vga_addr + 1;
      // Increment address on CPU cycle after IO read
      r_vga_rd <= vga_rd;
      if (r_vga_rd && !vga_rd) vga_addr <= vga_addr + 1;

      // Clear second address byte flag on VDP ctrl read or data read or write
      if ((cpuAddress[7:0] == vdp_ctrl_port && n_ioRD == 1'b0) || vga_rd || vga_wr) is_second_addr_byte <= 0;
      if (cpuAddress[7:0] == vdp_ctrl_port && n_ioWR == 1'b0) begin
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
      end else if (cpuAddress[7:0] == mem_ctrl_port && n_ioWR == 1'b0) begin
        r_mem_ctrl <= cpuDataOut; // Memory control write
      end
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
    .sprite5(sprite5),
    .interrupt_flag(interrupt_flag),
    .x_scroll(x_scroll),
    .y_scroll(y_scroll),
    .cram_selected(cram_selected),
    .disable_vert(r_vdp[0][7]),
    .disable_horiz(r_vdp[0][6]),
    .backdrop_color(r_vdp[7][3:0]),
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
    .i_csn(~wifi_gpio5), .i_sclk(wifi_gpio16), .i_mosi(sd_d[1]), // .o_miso(),
    .o_r(osd_vga_r), .o_g(osd_vga_g), .o_b(osd_vga_b),
    .o_hsync(osd_vga_hsync), .o_vsync(osd_vga_vsync), .o_blank(osd_vga_blank)
  );

  // Convert VGA to HDMI
  HDMI_out vga2dvid (
    .pixclk(clk_vga),
    .pixclk_x5(clk_hdmi),
    .red  (osd_vga_r),
    .green(osd_vga_g),
    .blue (osd_vga_b),
    .vde  (~osd_vga_blank),
    .hSync(~osd_vga_hsync),
    .vSync(~osd_vga_vsync),
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
  wire [7:0] status = {r_interrupt_flag, too_many_sprites, r_sprite_collision, (too_many_sprites ? sprite5 : 5'b11111)};
  wire [7:0] joy_data = {~btn[2:1], ~btn[6:1]};

  assign cpuDataIn =  cpuAddress[7:0] == vdp_data_port && n_ioRD == 1'b0 ? vga_dout :
                      cpuAddress[7:0] == vdp_ctrl_port && n_ioRD == 1'b0 ? status :
		      // Controllers 0 and 1
		      cpuAddress[7:0] == ctrl_0_port && n_ioRD == 1'b0 ? joy_data :
		      cpuAddress[7:0] == ctrl_1_port && n_ioRD == 1'b0 ? joy_data :
		      cpuAddress[7:0] == ctrl_2_port && n_ioRD == 1'b0 ? joy_data :
                      cpuAddress[15:14] < 3 && n_memRD == 1'b0 ? 
                        (r_mem_ctrl[3] == 0 ? biosOut : 8'hff) : ramOut;

  // Sprite collision interrupt
  always @(posedge cpuClock) begin
    if (!n_hard_reset) begin
      r_interrupt_flag <= 0;
      r_sprite_collision <= 0;
    end else begin
      if (interrupt_flag) r_interrupt_flag <= 1;
      if (sprite_collision) r_sprite_collision <= 1;
      if (cpuClockEdge) begin
        r_status_read <= cpuAddress[7:0] == vdp_ctrl_port && n_ioRD == 1'b0;
        if (r_status_read && !(cpuAddress[7:0] == vdp_ctrl_port && n_ioRD == 1'b0)) begin
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
  wire [3:0] sound_ao;

  assign audio_l = sound_ao;
  assign audio_r = audio_l;

  sn76489 #(4) audio (
    .clk(cpuClock),
    .clk_en(cpuClockEnable),
    .reset(!n_hard_reset),
    .ce_n(1'b0),
    .we_n(!(cpuAddress[7:0] == psg_write_port && n_ioWR == 1'b0)),
    .ready(sound_ready),
    .d(cpuDataOut),
    .audio_out(sound_ao)
  );

  // ===============================================================
  // Leds
  // ===============================================================
  assign led = {pc[15:14], !n_hard_reset, mode};

  always @(posedge cpuClock) diag16 <= sprite_pattern_table_addr;

endmodule
