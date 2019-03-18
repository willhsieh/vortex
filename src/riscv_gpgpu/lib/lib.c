#include "lib.h"


extern void createThreads(unsigned, unsigned, unsigned, void *, unsigned);
extern void        wspawn(unsigned, unsigned, unsigned, void *, unsigned);
extern void  print_consol(char *);
extern void        printc(char);


void int_print(unsigned f)
{
	if (f < 16)
	{
		print_consol(hextoa[f]);
		return;
	}
	int temp;
	int sf = 32;
	bool start = false;
	do
	{
		temp = (f >> (sf - 4)) & 0xf;
		if (temp != 0) start = true;
		if (start) print_consol(hextoa[temp]);
		sf -= 4;
	} while(sf > 0);
}

void reschedule_warps()
{

	register unsigned curr_warp asm("s10");

	if (queue_isEmpty(q+curr_warp))
	{
		done[curr_warp] = true;
		ECALL;
	}

	Job j;
	queue_dequeue(q+curr_warp,&j);
	asm __volatile__("mv sp,%0"::"r" (j.base_sp):);
	createThreads(j.n_threads, j.wid, j.func_ptr, j.args, j.assigned_warp);

	ECALL;

}

void schedule_warps()
{
	asm __volatile__("mv s3, sp");

	for (int curr_warp = 0; curr_warp < 7; ++curr_warp)
	{
		if (!queue_isEmpty(q+curr_warp)) 
		{
			Job j;
			queue_dequeue(q+curr_warp,&j);
			asm __volatile__("mv sp,%0"::"r" (j.base_sp):);
			wspawn(j.n_threads, j.wid, j.func_ptr, j.args, j.assigned_warp);
		}
	}

	asm __volatile__("mv sp, s3");

}

void sleep(int t)
{
	for(int z = 0; z < t; z++) {}
}



void createWarps(unsigned num_Warps, unsigned num_threads, FUNC, void * args)
{
	asm __volatile__("addi s2, sp, 0");
	int warp = 0;
	for (unsigned i = 0; i < num_Warps; i++)
	{
		asm __volatile__("lui s3, 0xFFFF0");
		asm __volatile__("add sp, sp, s3");
		register unsigned stack_ptr asm("sp");

		Job j;
		j.wid       = i;
		j.n_threads = num_threads;
		j.base_sp   = stack_ptr;
	    j.func_ptr  = (unsigned) func;
	    j.args      = args;
	    j.assigned_warp = warp;

	    queue_enqueue(q + warp,&j);
	    ++warp;
	    if (warp >= 7) warp = 0;
	}
	asm __volatile__("addi sp, s2, 0");


	schedule_warps();

}

void wait_for_done(unsigned num_wait)
{
	bool temp = false;
	while (!temp)
	{
		temp = true;
		for (int i = 0; i < num_wait; i++)
		{
			temp &= done[i];
		}
	}
}


void * get_1st_arg(void)
{
	register void *ret asm("s7");
	return ret;
}
void * get_2nd_arg(void)
{
	register void *ret asm("s8");
	return ret;
}
void * get_3rd_arg(void)
{
	register void *ret asm("s9");
	return ret;
}
