`include "common.vh"

module MyDesign(
    input logic reset_n,
    input logic clk,
    input logic dut_valid,
    output logic dut_ready,

    // SRAM Input Interface
    output logic dut__tb__sram_input_write_enable,
    output logic [`SRAM_ADDR_RANGE] dut__tb__sram_input_write_address,
    output logic [`SRAM_DATA_RANGE] dut__tb__sram_input_write_data,
    output logic [`SRAM_ADDR_RANGE] dut__tb__sram_input_read_address,
    input logic [`SRAM_DATA_RANGE] tb__dut__sram_input_read_data,     

    // SRAM Weight Interface
    output logic dut__tb__sram_weight_write_enable,
    output logic [`SRAM_ADDR_RANGE] dut__tb__sram_weight_write_address,
    output logic [`SRAM_DATA_RANGE] dut__tb__sram_weight_write_data,
    output logic [`SRAM_ADDR_RANGE] dut__tb__sram_weight_read_address,
    input logic [`SRAM_DATA_RANGE] tb__dut__sram_weight_read_data,     

    // SRAM Result Interface
    output logic dut__tb__sram_result_write_enable,
    output logic [`SRAM_ADDR_RANGE] dut__tb__sram_result_write_address,
    output logic [`SRAM_DATA_RANGE] dut__tb__sram_result_write_data,
    output logic [`SRAM_ADDR_RANGE] dut__tb__sram_result_read_address,
    input logic [`SRAM_DATA_RANGE] tb__dut__sram_result_read_data,
    
    // Scratchpad SRAM Interface
    output logic dut__tb__sram_scratchpad_write_enable,
    output logic [`SRAM_ADDR_RANGE] dut__tb__sram_scratchpad_write_address,
    output logic [`SRAM_DATA_RANGE] dut__tb__sram_scratchpad_write_data,
    output logic [`SRAM_ADDR_RANGE] dut__tb__sram_scratchpad_read_address,
    input logic [`SRAM_DATA_RANGE] tb__dut__sram_scratchpad_read_data
);


typedef enum logic [2:0] {
    IDLE,
    READ_DIM,
    READ_INPUT,
    ACCUMULATE,
    WRITE_DATA,
    DONE
} state_t;

state_t current_state, next_state;
// Registers for internal use
logic [31:0]  accum_result;
logic [31:0]  temp_result;
// Registers to hold read data
logic [31:0]  input_data;
logic [14:0] input_address;			//weight matrix is 3 times of the input matrix, hence, we need not have all 14 bits for input matrix 
logic [31:0]  weight_data;
logic [15:0] weight_address;

// Registers to hold matrix dimensions
logic [13:0] matrix_a_rows;			//mathematically impossible to have rows greater than 13 bits as we have to write results also in 15 bits only
logic [15:0] matrix_a_cols;
logic [13:0] matrix_b_cols;
logic [14:0] total_elements_b;			//3 times total elements in b must be less than 16 bits, hence total elements b must be less than 15 bits 
logic [13:0] total_writes;
// Counters for loops
logic [13:0] row_counter;
logic [15:0] a_column_counter;
logic [13:0] b_element_counter;
logic [13:0] b_column_counter;			//used only in the computation of attention
logic [13:0] write_count;			//as we have a different exit condition for the last computation, using write_count to exit helps
// Address counters
logic [15:0] result_addr;
logic [13:0] scratchpad_addr;			//Mathematically not possible to use complete scratchpad, as it requires to store only 2 matrices, which would be one fourth of the total result address size at max
logic first_write;				//due to the pipeleling, we need to wait for the accumuator to perform the write, we dont need to write at the first write_data state we go in every matrix
logic [15:0] col_dims;
//control signals
logic set_dut_ready;
logic compute_complete;
logic read_addr_sel ;
logic write_enable_sel;
logic [2:0]done_count;
always @(posedge clk) begin : proc_current_state_fsm
  if(!reset_n) begin // Synchronous reset
    current_state <= IDLE;
  end else begin
    current_state <= next_state;
  end
end
// DUT ready handshake logic
always @(posedge clk) begin : proc_compute_complete
  if(!reset_n) begin
    compute_complete <= 0;
  end else begin
    compute_complete <= (set_dut_ready) ? 1'b1 : 1'b0;
  end
end

assign dut_ready = compute_complete;

// Find the number of matrix elements and setup counters 
always @(posedge clk) begin : proc_matrix_size
  if(!reset_n) begin
    matrix_a_rows <= 0;
    matrix_a_cols <= 0;
    matrix_b_cols <= 0;
    dut__tb__sram_input_write_enable <= 0;
    dut__tb__sram_weight_write_enable <= 0;
  end else begin
   if (current_state==READ_DIM) begin
    matrix_a_rows <= tb__dut__sram_input_read_data[31:16];
    matrix_a_cols <= tb__dut__sram_input_read_data[15:0];
    matrix_b_cols <= tb__dut__sram_weight_read_data[15:0];
    total_elements_b <= tb__dut__sram_input_read_data[15:0] * tb__dut__sram_weight_read_data[15:0];
    total_writes <=tb__dut__sram_input_read_data[31:16]*tb__dut__sram_weight_read_data[15:0]; 
   end
  end
end

// Initialize `done_count` in the reset condition
always @(posedge clk) begin
  if (!reset_n || current_state == IDLE) begin
    done_count <= 3'b000;
  end else if (current_state == DONE ) begin 
    done_count <= done_count + 1;
  end
end

assign col_dims = (done_count<3) ? matrix_a_cols : 
                  (done_count==3) ? matrix_b_cols : 
                  (done_count==4)  ? matrix_a_rows : 
                   0;
always @(posedge clk) begin  
  if(!reset_n) begin // Synchronous reset
    first_write <= 0;
  end else begin
    if (current_state==DONE)
    	first_write <= 0;
    else if (current_state==WRITE_DATA)
    	first_write <= 1;
  end
end

// SRAM read address generator
always @(posedge clk) begin
    if (!reset_n|| current_state == IDLE) begin
      input_address  <= 1'b0;
      weight_address <= 1'b0;
      row_counter <= 1'b0;
      a_column_counter <= 1'b0;
      b_element_counter <= 1'b0;
      b_column_counter <= 1'b1;
      write_count <= 1'b0;
    end
    else begin
     if (done_count<3) begin
      if (read_addr_sel == 1'b0) begin
        input_address <= 1'b0;
	weight_address <= 1'b0;
        a_column_counter <= 1'b0;
        row_counter <= 1'b0;
        b_element_counter <= 1'b0;
      end
      else if (read_addr_sel == 1'b1) begin
      	input_address <= 12'h001  + (row_counter * matrix_a_cols) + a_column_counter;
        weight_address <= 12'h001 + b_element_counter + done_count * total_elements_b;
	if (a_column_counter == matrix_a_cols -1 && b_element_counter != total_elements_b -1) begin
                    a_column_counter <= 0;  
	            b_element_counter <= b_element_counter + 1;
        end else if (b_element_counter == total_elements_b-1) begin
	        row_counter <= row_counter + 1;  		//to ensure data is seen in the next rising edge
	        a_column_counter <= 0;
		b_element_counter <= 0;
	    end 
            else if (a_column_counter < matrix_a_cols-1 && b_element_counter != total_elements_b -1 ) begin
	        a_column_counter <= a_column_counter + 1;
	        b_element_counter <= b_element_counter + 1; 
	    end 
     end	
    end

//for the score matrix
	else if (done_count==3) begin
      if (read_addr_sel == 1'b0) begin
        input_address <= 1'b0;
	weight_address <= 1'b0;
        a_column_counter <= 1'b0;
        row_counter <= 1'b0;
        b_element_counter <= 1'b0;
      end
      else if (read_addr_sel == 1'b1) begin
      	input_address <=  (row_counter * matrix_b_cols) + a_column_counter;
        weight_address <=  b_element_counter;
	if (a_column_counter == matrix_b_cols -1 && b_element_counter != total_writes -1) begin
                    a_column_counter <= 0;  
	            b_element_counter <= b_element_counter + 1;
        end else if (b_element_counter == total_writes-1) begin
	        row_counter <= row_counter + 1;  		//to ensure data is seen in the next rising edge
	        a_column_counter <= 0;
		b_element_counter <= 0;
	    end 
            else if (a_column_counter < matrix_b_cols-1 && b_element_counter != total_writes -1 ) begin
	        a_column_counter <= a_column_counter + 1;
	        b_element_counter <= b_element_counter + 1; 
	    end 
     end	
    end
//done for score matrix
//
//for the attention matrix
//
	else if (done_count ==4) begin
      if (read_addr_sel == 1'b0) begin
        input_address <= 1'b0;
	weight_address <= 1'b0;
        a_column_counter <= 1'b0;
        row_counter <= 1'b0;
        b_element_counter <= 1'b0;
	b_column_counter <= 1'b1;
      end
      else if (read_addr_sel == 1'b1) begin
      	input_address <=  (row_counter * matrix_a_rows) + a_column_counter + total_writes + total_writes +total_writes; 	//using addition 3 times instead of multiplier
        weight_address <=  b_element_counter + total_writes;
	if (a_column_counter == matrix_a_rows -1 && b_element_counter != total_writes -1) begin
                    a_column_counter <= 0;  
	            b_element_counter <= b_column_counter;
		    b_column_counter <= b_column_counter +1;
		    write_count <= write_count +1;
        end else if (b_element_counter == total_writes-1) begin
	        row_counter <= row_counter + 1;  		//to ensure data is seen in the next rising edge
	        a_column_counter <= 0;
		b_element_counter <= 0;
		b_column_counter <= 1;
	    end 
            else if (a_column_counter < matrix_a_rows-1 && b_element_counter != total_writes -1 ) begin
	        a_column_counter <= a_column_counter + 1;
	        b_element_counter <= b_element_counter + matrix_b_cols; 
	    end 
     end	
end

    end
 end

assign dut__tb__sram_input_read_address = (done_count<3)? input_address : 0;
assign dut__tb__sram_weight_read_address = (done_count<3)? weight_address : 0;

assign dut__tb__sram_result_read_address = (done_count>2)? input_address : 0;
assign dut__tb__sram_scratchpad_read_address = (done_count>2)? weight_address : 0;


// Accumulation logic 
always @(posedge clk) begin : proc_accumulation
  if(!reset_n|| current_state == IDLE) begin
    input_data   <= 1'b0;
    weight_data  <= 1'b0;
    accum_result <= 1'b0;
  end else begin
    accum_result <= accum_result;
    if (done_count <3) begin
    	input_data <= tb__dut__sram_input_read_data;
    	weight_data <= tb__dut__sram_weight_read_data;
    end else if(done_count >2) begin
    	input_data <= tb__dut__sram_result_read_data;
    	weight_data <= tb__dut__sram_scratchpad_read_data;
    end
	if (current_state == WRITE_DATA) 
		accum_result <= 0;
	else 
		accum_result <= accum_result + temp_result;
   end
end
assign temp_result = input_data*weight_data;
// SRAM write address logic
always @(posedge clk) begin : proc_sram_write_address_r
  if(!reset_n || current_state == IDLE) begin
    result_addr <= 0;
    scratchpad_addr <= 0;
  end else begin
    result_addr <= write_enable_sel ? result_addr + 1 : result_addr; 
    if (done_count)	
	scratchpad_addr <= write_enable_sel ? scratchpad_addr + 1 : scratchpad_addr;
  end
end
 assign dut__tb__sram_result_write_enable = write_enable_sel;
 assign dut__tb__sram_result_write_address = result_addr;
 assign dut__tb__sram_result_write_data = write_enable_sel ? (accum_result + temp_result) : 0;
 assign dut__tb__sram_scratchpad_write_enable = write_enable_sel && (done_count==2 ||done_count ==1);
 assign dut__tb__sram_scratchpad_write_address = scratchpad_addr;
 assign	dut__tb__sram_scratchpad_write_data = write_enable_sel ? (accum_result + temp_result) : 0;

always @(*) begin : proc_next_state_fsm
  next_state          = IDLE;
  case (current_state)
    IDLE                    : begin
	if (dut_valid) begin
		set_dut_ready       = 1'b0;
        	read_addr_sel       = 1'b0;
        	write_enable_sel    = 1'b0;
        	next_state          = READ_DIM;
      	end
      	else begin
        	set_dut_ready       = 1'b1;
        	read_addr_sel       = 1'b0;
        	write_enable_sel    = 1'b0;
        	next_state          = IDLE;
      	end
    end
    READ_DIM  : begin
      set_dut_ready         = 1'b0;
      read_addr_sel         = 1'b0;  
      write_enable_sel      = 1'b0;
      next_state            = READ_INPUT;
    end 
    READ_INPUT: begin
      set_dut_ready         = 1'b0;
      read_addr_sel         = 1'b1;  // Increment the read addr
      write_enable_sel      = 1'b0;
      next_state            = ACCUMULATE;    
    end
    ACCUMULATE: begin
      set_dut_ready         = 1'b0;
      read_addr_sel         = 1'b1;  // Increment the read addr
      write_enable_sel      = 1'b0;
      if (a_column_counter !=1 && col_dims>1 )
      	next_state            = ACCUMULATE; 
      else 
	next_state = WRITE_DATA;   
    end
    WRITE_DATA: begin
      set_dut_ready         = 1'b0;
      read_addr_sel         = 1'b1;  
      write_enable_sel      = first_write? 1'b1: 1'b0;
      if (col_dims<2 ) begin
	if (write_count<total_writes+1)
		next_state = WRITE_DATA;
	else 
		next_state = DONE;
      end

      else begin
	if (done_count !=4) begin
      if (row_counter == matrix_a_rows && b_element_counter==2)			//Ideally should've been b_element_counter ==0 but due to our efficient pipeline, we are taking 2 cycles
      	next_state = DONE;
      else 
		next_state = ACCUMULATE; 
      end
      else if (done_count ==4) begin
	if (write_count > total_writes)			//Ideally should've been b_element_counter ==0 but due to our efficient pipeline, we are taking 2 cycles
      	next_state = DONE;
      else 
		next_state = ACCUMULATE; 
      end
	end
    end
    DONE: begin
      set_dut_ready         = 1'b0;
      read_addr_sel         = 1'b0;  
      write_enable_sel      = 1'b0;
      if (done_count ==4)
	next_state = IDLE;
      else   
	next_state = READ_INPUT;   
    end
	
    default                 :  begin
      set_dut_ready         = 1'b1;
      read_addr_sel         = 1'b0;  
      write_enable_sel      = 1'b0;
      next_state = IDLE;    
    end

endcase
end
endmodule
